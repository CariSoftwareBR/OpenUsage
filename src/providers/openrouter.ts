import { homedir } from "node:os"
import { join } from "node:path"
import { findKey, type KeySpec } from "./keys.ts"
import { clampPct, getJson, ProviderError, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

const API = "https://openrouter.ai/api/v1"

const KEY: KeySpec = {
  id: "openrouter",
  toolIds: ["openrouter"],
  envs: ["OPENROUTER_API_KEY", "OPENROUTER_KEY"],
  files: [join(homedir(), ".config", "openrouter", "key.json")],
  anthropicHost: "openrouter.ai",
}

const usd = (n: number) => `$${n.toFixed(2)}`
const num = (v: unknown) => (v == null || v === "" ? undefined : Number.isFinite(Number(v)) ? Number(v) : undefined)

async function usage(key: string, signal?: AbortSignal): Promise<ProviderUsage> {
  const headers = { Authorization: `Bearer ${key}`, Accept: "application/json" }
  // /credits is the balance and is required; /key (tier, period spend, key cap) is best-effort.
  const [credits, info] = await Promise.all([
    getJson(`${API}/credits`, { signal, headers }, "OpenRouter").then(
      (b) => b?.data,
      (e) => {
        throw /sign in/.test(String(e?.message)) ? new ProviderError("OpenRouter: API key rejected") : e
      },
    ),
    getJson(`${API}/key`, { signal, headers }, "OpenRouter").then(
      (b) => b?.data,
      () => undefined,
    ),
  ])
  const used = num(credits?.total_usage)
  if (used == null) throw new ProviderError("OpenRouter: no usage data")

  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  const total = Math.max(0, num(credits.total_credits) ?? 0)
  // A never-topped-up account reports 0 credits: no meter, just the balance.
  if (total > 0) windows.push({ label: "Credits", usedPct: clampPct((used / total) * 100) })
  extras.push({ label: "Balance", value: usd(Math.max(0, total - used)) })

  const limit = num(info?.limit)
  if (limit && limit > 0) {
    const left = Math.max(0, num(info.limit_remaining) ?? 0)
    windows.push({ label: "Key Limit", usedPct: clampPct(((limit - left) / limit) * 100) })
  }
  for (const [field, label] of [
    ["usage_daily", "Today"],
    ["usage_weekly", "This Week"],
    ["usage_monthly", "This Month"],
  ] as const) {
    const v = num(info?.[field])
    if (v != null) extras.push({ label, value: usd(Math.max(0, v)) })
  }
  const plan = typeof info?.is_free_tier === "boolean" ? (info.is_free_tier ? "free" : "pay as you go") : undefined
  return { id: "openrouter", name: "OpenRouter", ...(plan ? { plan } : {}), windows, extras, fetchedAt: Date.now() } satisfies ProviderUsage
}

export const openrouter: Provider = {
  id: "openrouter",
  name: "OpenRouter",
  async fetch(signal) {
    const found = await findKey(KEY)
    if (!found) throw new ProviderError("no OpenRouter API key, add it in Settings")
    return usage(found.key, signal)
  },
  detect: () => findKey(KEY).then(Boolean),
  apiKey: { spec: KEY, url: "https://openrouter.ai/keys", check: (key, signal) => usage(key, signal).then(() => {}) },
}
