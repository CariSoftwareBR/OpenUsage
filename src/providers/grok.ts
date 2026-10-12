import { readFile, rename, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, jwtPayload, ProviderError, toMillis, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// The same calls the Grok CLI makes for `/usage`.
const API = "https://cli-chat-proxy.grok.com/v1"
const TOKEN_URL = "https://auth.x.ai/oauth2/token"
const DEFAULT_CLIENT_ID = "b1a00492-073a-47ea-816f-4c329264a828"

const authPath = () => join(process.env.GROK_HOME ?? join(homedir(), ".grok"), "auth.json")

interface Entry {
  key?: string
  refresh_token?: string
  refresh?: string
  id_token?: string
  expires_at?: string
  expires?: string
  oidc_client_id?: string
}

/** What `grok login` saved: one entry per login, keyed "<issuer>::<client id>". */
async function readAuth(): Promise<Record<string, Entry>> {
  const raw = await readFile(authPath(), "utf8").catch(() => undefined)
  if (!raw) throw new ProviderError("not signed in to Grok, run grok login")
  const auth = JSON.parse(raw)
  if (!auth || typeof auth !== "object" || !Object.values(auth).some((e: any) => e?.key)) throw new ProviderError("Grok: sign in again, run grok login")
  return auth
}

function expiresAt(e: Entry): number | undefined {
  const exp = jwtPayload(e.key ?? "")?.exp
  return typeof exp === "number" ? exp * 1000 : toMillis(e.expires_at ?? e.expires)
}

/**
 * Trades the refresh token for a new access token and writes both back, like the CLI does:
 * the refresh token rotates, so the CLI must find the new one in auth.json.
 */
async function refresh(entryKey: string, e: Entry): Promise<string | undefined> {
  const refreshToken = (e.refresh_token ?? e.refresh)?.trim()
  if (!refreshToken) return undefined
  const clientId = e.oidc_client_id?.trim() || entryKey.split("::").pop()?.trim() || DEFAULT_CLIENT_ID
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    signal: AbortSignal.timeout(15_000),
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: refreshToken }),
  }).catch(() => undefined)
  if (!res?.ok) return undefined
  const t: any = await res.json().catch(() => undefined)
  const access = typeof t?.access_token === "string" ? t.access_token.trim() : ""
  if (!access) return undefined
  const exp = Number(t.expires_in) > 0 ? Date.now() + Number(t.expires_in) * 1000 : (expiresAt({ key: access }) ?? Date.now() + 3_600_000)
  // Re-read so an entry the CLI changed meanwhile, or another login, isn't lost.
  const path = authPath()
  try {
    const auth = JSON.parse(await readFile(path, "utf8"))
    auth[entryKey] = {
      ...auth[entryKey],
      key: access,
      ...(t.refresh_token ? { refresh_token: t.refresh_token } : {}),
      ...(t.id_token ? { id_token: t.id_token } : {}),
      expires_at: new Date(exp).toISOString(),
    }
    await writeFile(`${path}.tmp`, JSON.stringify(auth, null, 2), { mode: 0o600 })
    await rename(`${path}.tmp`, path)
  } catch {
    // The new token still works for this refresh.
  }
  return access
}

const headers = (token: string) => ({
  Authorization: `Bearer ${token.trim()}`,
  "X-XAI-Token-Auth": "xai-grok-cli",
  Accept: "application/json",
  "User-Agent": "OpenUsage",
})

async function usage(token: string, signal?: AbortSignal): Promise<ProviderUsage> {
  const [billing, settings] = await Promise.all([
    fetch(`${API}/billing?format=credits`, { signal: signal ?? AbortSignal.timeout(15_000), headers: headers(token) }),
    fetch(`${API}/settings`, { signal: signal ?? AbortSignal.timeout(15_000), headers: headers(token) }).then(
      (r): Promise<any> => (r.ok ? r.json() : Promise.resolve(undefined)),
      () => undefined,
    ),
  ])
  if (billing.status === 401 || billing.status === 403) throw Object.assign(new ProviderError("Grok: sign in again, run grok login"), { auth: true })
  const plan = typeof (settings as any)?.subscription_tier_display === "string" ? (settings as any).subscription_tier_display.trim() || undefined : undefined
  const base = { id: "grok" as const, name: "Grok", ...(plan ? { plan } : {}), fetchedAt: Date.now() }
  const body: any = await billing.json().catch(() => undefined)
  // A team login has no personal pool to show.
  if (billing.status === 412 && /no personal team/i.test(String(body?.error ?? "")))
    return { ...base, windows: [], extras: [{ label: "Weekly", value: "team accounts have no personal quota" }] }
  if (!billing.ok) throw new ProviderError(`Grok: HTTP ${billing.status}`)
  const config = body?.config
  const period = config?.currentPeriod
  if (!period?.type) throw new ProviderError("Grok: no usage data")

  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  // Proto-JSON drops zeros: no creditUsagePercent means 0%. Accounts still on monthly billing have no weekly pool.
  if (period.type === "USAGE_PERIOD_TYPE_WEEKLY")
    windows.push({ label: "Weekly", usedPct: clampPct(config.creditUsagePercent ?? 0), resetsAt: toMillis(period.end) })
  const cap = Number(config.onDemandCap?.val ?? 0) || 0
  extras.push({ label: "Pay as you go", value: cap > 0 ? `${cap} cap` : "disabled" })
  return { ...base, windows, extras }
}

export const grok: Provider = {
  id: "grok",
  name: "Grok",
  async fetch(signal) {
    const auth = await readAuth()
    let lastError: unknown = new ProviderError("Grok: sign in again, run grok login")
    for (const [entryKey, e] of Object.entries(auth)) {
      if (!e?.key) continue
      let token: string | undefined = e.key
      const exp = expiresAt(e)
      // Refresh a few minutes early; an expired login that can't refresh moves on to the next one.
      if (exp && exp - Date.now() < 5 * 60_000) {
        token = (await refresh(entryKey, e)) ?? (exp > Date.now() ? e.key : undefined)
        if (!token) continue
      }
      try {
        return await usage(token, signal)
      } catch (err) {
        lastError = err
        if (!(err as any)?.auth) throw err
        // Rejected before it expired: one refresh and retry.
        const fresh = await refresh(entryKey, e)
        if (fresh) return usage(fresh, signal)
      }
    }
    throw lastError
  },
  account: () => readAuth().then((a) => Object.values(a).find((e: any) => e?.key && e.email) as any).then((e) => e?.email),
  detect: () => readAuth().then(() => true, () => false),
}
