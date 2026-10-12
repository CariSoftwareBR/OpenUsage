import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, getJson, ProviderError, toMillis, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// The same calls the Kilo CLI makes for its balance and Kilo Pass bars.
const API = process.env.KILO_API_URL || "https://api.kilo.ai"

const dataDir = () => join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "kilo")

/** What `kilo auth login` saved for the Kilo account. */
async function readToken(): Promise<string> {
  const raw = await readFile(join(dataDir(), "auth.json"), "utf8").catch(() => undefined)
  const cred = raw ? JSON.parse(raw)?.kilo : undefined
  const token = cred?.access ?? cred?.key
  if (!token) throw new ProviderError("not signed in to Kilo, run kilo auth login")
  if (cred.expires && cred.expires < Date.now()) throw new ProviderError("token expired, open Kilo")
  return token
}

const usd = (n: number) => `$${n.toFixed(2)}`
const num = (v: unknown) => (typeof v === "number" ? v : Number(v ?? 0)) || 0

/** The organization the CLI bills to: the selected one, or the first when there is no personal account. */
function orgOf(profile: any): string | undefined {
  const orgs: any[] = profile?.organizations ?? []
  const sel = profile?.selectedOrganizationId
  if (sel && orgs.some((o) => o.id === sel)) return sel
  return profile?.hasPersonalAccount === false ? orgs[0]?.id : undefined
}

/** tRPC batch reply -> the Kilo Pass subscription, when one is active. */
function passOf(body: any): any {
  const first = Array.isArray(body) ? body[0] : body
  const data = first?.result?.data
  const sub = (data?.json ?? data)?.subscription
  if (!sub || (sub.currentPeriodBaseCreditsUsd == null && sub.currentPeriodUsageUsd == null)) return undefined
  if (typeof sub.status === "string" && !["active", "past_due", "trialing"].includes(sub.status)) return undefined
  return sub
}

export const kilo: Provider = {
  id: "kilo",
  name: "Kilo",
  async fetch(signal) {
    const token = await readToken()
    const headers = { Authorization: `Bearer ${token}`, Accept: "application/json" }
    const profile = await getJson(`${API}/api/profile`, { signal, headers }, "Kilo")
    const org = orgOf(profile)
    const query = new URLSearchParams({ batch: "1", input: JSON.stringify({ "0": null }) })
    const [balance, pass] = await Promise.all([
      getJson(`${API}/api/profile/balance`, { signal, headers: { ...headers, ...(org ? { "x-kilocode-organizationid": org } : {}) } }, "Kilo").catch(
        () => undefined,
      ),
      getJson(`${API}/api/trpc/kiloPass.getState?${query}`, { signal, headers }, "Kilo").then(passOf, () => undefined),
    ])

    const windows: UsageWindow[] = []
    const extras: UsageExtra[] = []
    if (pass) {
      const included = num(pass.currentPeriodBaseCreditsUsd) + num(pass.currentPeriodBonusCreditsUsd)
      const used = num(pass.currentPeriodUsageUsd)
      if (included > 0)
        windows.push({ label: "Monthly", usedPct: clampPct((used / included) * 100), resetsAt: toMillis(pass.nextBillingAt ?? pass.nextRenewalAt) })
      extras.push({ label: "Kilo Pass", value: `${usd(used)} / ${usd(included)}` })
    }
    if (balance && balance.balance != null) extras.push({ label: "Credits", value: usd(num(balance.balance)) })
    if (!windows.length && !extras.length) throw new ProviderError("Kilo: no usage data")
    const email = profile?.user?.email ?? profile?.email
    return {
      id: "kilo",
      name: "Kilo",
      ...(pass ? { plan: "pass" } : {}),
      ...(email ? { account: String(email) } : {}),
      windows,
      extras,
      fetchedAt: Date.now(),
    } satisfies ProviderUsage
  },
  // Signed in at some point, even if the token has expired since: the card then says to open Kilo.
  detect: () =>
    readFile(join(dataDir(), "auth.json"), "utf8").then(
      (raw) => !!JSON.parse(raw)?.kilo,
      () => false,
    ),
}
