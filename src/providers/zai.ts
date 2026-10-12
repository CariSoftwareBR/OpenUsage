import { homedir } from "node:os"
import { join } from "node:path"
import { findKey, type KeySpec } from "./keys.ts"
import { clampPct, ProviderError, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// Undocumented, but they are what Z.ai's own subscription page calls.
const QUOTA_URL = "https://api.z.ai/api/monitor/usage/quota/limit"
const SUBSCRIPTION_URL = "https://api.z.ai/api/biz/subscription/list"

const KEY: KeySpec = {
  id: "zai",
  // OpenCode / Kilo file the GLM Coding Plan as "zai-coding-plan"; the pay-per-use API key works for the quota too.
  toolIds: ["zai-coding-plan", "zai"],
  envs: ["ZAI_API_KEY", "GLM_API_KEY"],
  files: [join(homedir(), ".config", "zai", "key.json")],
  anthropicHost: "api.z.ai",
}

const HOUR = 3_600_000
/** Window length of a limit entry: `unit` 3 = hours, 4 = days, 5 = months, 6 = weeks, times `number`. */
const UNIT_MS: Record<number, number> = { 3: HOUR, 4: 24 * HOUR, 5: 30 * 24 * HOUR, 6: 7 * 24 * HOUR }

const typeOf = (l: any) => l?.type ?? l?.name
const resetOf = (l: any) => (Number.isFinite(Number(l?.nextResetTime)) && l.nextResetTime ? Number(l.nextResetTime) : undefined)

async function get(url: string, key: string, signal?: AbortSignal): Promise<Response> {
  return fetch(url, { signal: signal ?? AbortSignal.timeout(15_000), headers: { Authorization: `Bearer ${key}`, Accept: "application/json" } })
}

async function usage(key: string, signal?: AbortSignal): Promise<ProviderUsage> {
  const [quota, sub] = await Promise.all([
    get(QUOTA_URL, key, signal),
    get(SUBSCRIPTION_URL, key, signal).then(
      (r): Promise<any> => (r.ok ? r.json() : Promise.resolve(undefined)),
      () => undefined,
    ),
  ])
  if (quota.status === 401 || quota.status === 403) throw new ProviderError("Z.ai: API key rejected")
  if (!quota.ok) throw new ProviderError(`Z.ai: HTTP ${quota.status}`)
  const body: any = await quota.json()
  // A bad key also answers HTTP 200, with the 401 inside.
  if (body?.success === false && (body.code === 401 || body.code === 403)) throw new ProviderError("Z.ai: API key rejected")
  // A valid key without a GLM Coding Plan still answers 200, with success:false.
  if (body?.success === false && String(body?.msg ?? "").toLowerCase().includes("coding plan"))
    throw new ProviderError("no active GLM Coding Plan")
  const limits: any[] = (body?.data ?? body)?.limits
  if (!Array.isArray(limits)) throw new ProviderError("Z.ai: no usage data")

  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  // Percentage quotas (CREDIT_LIMIT, TOKENS_LIMIT on older plans): a sub-daily window is the session.
  for (const l of limits.filter((l) => ["CREDIT_LIMIT", "TOKENS_LIMIT"].includes(typeOf(l)))) {
    const ms = UNIT_MS[Number(l.unit)]
    if (!ms || !(Number(l.number) > 0) || l.percentage == null) continue
    const label = ms * Number(l.number) < 24 * HOUR ? "5-Hour" : "Weekly"
    windows.push({ label, usedPct: clampPct(l.percentage), resetsAt: resetOf(l) })
  }
  windows.sort((a, b) => (a.label === "5-Hour" ? -1 : b.label === "5-Hour" ? 1 : 0))
  // TIME_LIMIT: the monthly count of web searches / web reader / Zread calls.
  const web = limits.find((l) => typeOf(l) === "TIME_LIMIT")
  if (web && Number(web.usage) > 0) {
    windows.push({ label: "Web Searches", usedPct: clampPct((Number(web.currentValue) / Number(web.usage)) * 100), resetsAt: resetOf(web) })
    extras.push({ label: "Web Searches", value: `${Number(web.currentValue) || 0} / ${Number(web.usage)}` })
  }
  if (!windows.length) throw new ProviderError("Z.ai: no usage data")
  // "GLM Coding Max" -> "Max"
  const plan = typeof sub?.data?.[0]?.productName === "string" ? sub.data[0].productName.replace(/^\s*GLM Coding\s*/i, "").trim() : undefined
  return { id: "zai", name: "Z.ai", ...(plan ? { plan } : {}), windows, extras, fetchedAt: Date.now() } satisfies ProviderUsage
}

export const zai: Provider = {
  id: "zai",
  name: "Z.ai",
  async fetch(signal) {
    const found = await findKey(KEY)
    if (!found) throw new ProviderError("no Z.ai API key, add it in Settings")
    return usage(found.key, signal)
  },
  detect: () => findKey(KEY).then(Boolean),
  apiKey: { spec: KEY, url: "https://z.ai/manage-apikey/apikey-list", check: (key, signal) => usage(key, signal).then(() => {}) },
}
