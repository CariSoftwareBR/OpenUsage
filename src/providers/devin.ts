import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, ProviderError, sqliteGet, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// Connect RPC on Devin's (ex-Windsurf) API server, the call the Devin app makes for its quota bars.
const DEFAULT_SERVER = "https://server.codeium.com"
const RPC = "exa.seat_management_pb.SeatManagementService/GetUserStatus"
const COMPAT_VERSION = "1.108.2"

interface Auth {
  apiKey: string
  server?: string
}

/** `devin auth login` writes credentials.toml under the XDG data dir (also looked for in AppData on Windows). */
function credentialPaths(): string[] {
  const xdg = join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "devin", "credentials.toml")
  if (process.platform !== "win32") return [xdg]
  const appData = process.env.APPDATA ?? join(homedir(), "AppData", "Roaming")
  const local = process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local")
  return [xdg, join(appData, "devin", "credentials.toml"), join(local, "devin", "credentials.toml")]
}

/** The Devin app's VS Code state DB. */
function stateDbPath() {
  const rel = ["Devin", "User", "globalStorage", "state.vscdb"]
  if (process.platform === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), ...rel)
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", ...rel)
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), ...rel)
}

/** A top-level `key = "value"` from a TOML file; enough for credentials.toml. */
function tomlString(text: string, key: string): string | undefined {
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^\s*([\w.-]+)\s*=\s*(.*)$/)
    if (!m || m[1] !== key) continue
    const v = m[2]!.trim()
    const q = v[0]
    if (q === '"' || q === "'") {
      const end = v.indexOf(q, 1)
      return end > 0 ? v.slice(1, end).trim() || undefined : undefined
    }
    return v.replace(/#.*$/, "").trim() || undefined
  }
  return undefined
}

async function cliAuth(): Promise<Auth | undefined> {
  for (const path of credentialPaths()) {
    const text = await readFile(path, "utf8").catch(() => undefined)
    const apiKey = text && tomlString(text, "windsurf_api_key")
    if (!apiKey) continue
    const server = tomlString(text, "api_server_url")?.replace(/\/+$/, "")
    return { apiKey, ...(server?.startsWith("https://") ? { server } : {}) }
  }
  return undefined
}

async function appAuth(): Promise<Auth | undefined> {
  const path = stateDbPath()
  if (!existsSync(path)) return undefined
  const row = await sqliteGet(path, "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus' LIMIT 1").catch(() => undefined)
  const v = row?.value
  if (v == null) return undefined
  try {
    const apiKey = JSON.parse(typeof v === "string" ? v : new TextDecoder().decode(v as Uint8Array))?.apiKey?.trim()
    return apiKey ? { apiKey } : undefined
  } catch {
    return undefined
  }
}

/** Devin reports what remains; the bars show what's used. */
const usedOf = (remaining: number) => clampPct(100 - remaining)
const num = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? undefined : Number(v))
const secs = (v: unknown) => (num(v) ? num(v)! * 1000 : undefined)

function map(status: any): ProviderUsage {
  const ps = status?.planStatus ?? {}
  const info = ps.planInfo ?? {}
  const hideDaily = info.hideDailyQuota === true
  const daily = num(ps.dailyQuotaRemainingPercent)
  // Proto3 JSON drops zeros: a weekly reset with no percentage left means the week is used up.
  const weeklyReset = secs(ps.weeklyQuotaResetAtUnix)
  const weekly = num(ps.weeklyQuotaRemainingPercent) ?? (weeklyReset ? 0 : undefined)

  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  if (!hideDaily && daily != null) windows.push({ label: "Daily", usedPct: usedOf(daily), resetsAt: secs(ps.dailyQuotaResetAtUnix) })
  if (weekly != null) windows.push({ label: "Weekly", usedPct: usedOf(weekly), resetsAt: weeklyReset })
  // No weekly figure at all: the hidden daily one is the only quota there is.
  else if (hideDaily && daily != null) windows.push({ label: "Weekly", usedPct: usedOf(daily) })
  const micros = num(ps.overageBalanceMicros)
  if (micros != null) extras.push({ label: "Extra Balance", value: `$${(Math.max(0, micros) / 1e6).toFixed(2)}` })
  if (!windows.length && !extras.length) throw new ProviderError("Devin: no usage data")
  const plan = typeof info.planName === "string" ? info.planName.trim() || undefined : undefined
  return { id: "devin", name: "Devin", ...(plan ? { plan } : {}), windows, extras, fetchedAt: Date.now() }
}

async function userStatus(auth: Auth, signal?: AbortSignal): Promise<Response> {
  return fetch(`${auth.server ?? DEFAULT_SERVER}/${RPC}`, {
    method: "POST",
    signal: signal ?? AbortSignal.timeout(15_000),
    headers: { "Content-Type": "application/json", "Connect-Protocol-Version": "1" },
    body: JSON.stringify({
      metadata: {
        apiKey: auth.apiKey,
        ideName: "devin",
        ideVersion: COMPAT_VERSION,
        extensionName: "devin",
        extensionVersion: COMPAT_VERSION,
        locale: "en",
      },
    }),
  })
}

export const devin: Provider = {
  id: "devin",
  name: "Devin",
  async fetch(signal) {
    const sources = [await cliAuth(), await appAuth()].filter((a): a is Auth => !!a)
    if (!sources.length) throw new ProviderError("not signed in to Devin, run devin auth login")
    // No token refresh: a rejected CLI key falls back to the app's login.
    for (const auth of sources) {
      if (auth !== sources[0] && auth.apiKey === sources[0]!.apiKey) continue
      const res = await userStatus(auth, signal)
      if (res.status === 401 || res.status === 403) continue
      if (!res.ok) throw new ProviderError(`Devin: HTTP ${res.status}`)
      const body: any = await res.json()
      if (!body?.userStatus) throw new ProviderError("Devin: no usage data")
      return map(body.userStatus)
    }
    throw new ProviderError("Devin: sign in again, run devin auth login")
  },
  detect: async () => !!((await cliAuth()) ?? (await appAuth())),
}
