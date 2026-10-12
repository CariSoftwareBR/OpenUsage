import { existsSync } from "node:fs"
import { readdir, readFile, stat } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import {
  clampPct,
  getJson,
  jwtPayload,
  ProviderError,
  siblingProfiles,
  toMillis,
  type Provider,
  type ProviderUsage,
  type UsageExtra,
  type UsageWindow,
} from "./types.ts"

const home = () => process.env.CODEX_HOME ?? join(homedir(), ".codex")

function windowLabel(seconds: number | undefined, fallback: string) {
  if (!seconds) return fallback
  const hours = Math.round(seconds / 3600)
  if (hours >= 24 * 6) return "Weekly"
  if (hours >= 24) return `${Math.round(hours / 24)}-Day`
  return `${hours}-Hour`
}

async function readAuth(dir: string) {
  let raw: string
  try {
    raw = await readFile(join(dir, "auth.json"), "utf8")
  } catch {
    throw new ProviderError("not signed in to Codex")
  }
  const tokens = JSON.parse(raw)?.tokens
  if (!tokens?.access_token) throw new ProviderError("Codex uses an API key, no plan limits")
  return { token: tokens.access_token as string, accountId: tokens.account_id as string | undefined }
}

async function fromApi(dir: string, signal?: AbortSignal): Promise<ProviderUsage> {
  const { token, accountId } = await readAuth(dir)
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
    "User-Agent": "codex-cli",
    Accept: "application/json",
  }
  if (accountId) headers["ChatGPT-Account-Id"] = accountId
  const body = await getJson("https://chatgpt.com/backend-api/wham/usage", { signal, headers }, "Codex")

  const windows: UsageWindow[] = []
  const rl = body?.rate_limit
  for (const [w, fallback] of [
    [rl?.primary_window, "5-Hour"],
    [rl?.secondary_window, "Weekly"],
  ] as const) {
    if (!w) continue
    const resetsAt =
      toMillis(w.reset_at) ?? (w.reset_after_seconds != null ? Date.now() + w.reset_after_seconds * 1000 : undefined)
    windows.push({ label: windowLabel(w.limit_window_seconds, fallback), usedPct: clampPct(w.used_percent), resetsAt })
  }

  const extras: UsageExtra[] = []
  const credits = body?.credits
  if (credits && !credits.unlimited && credits.balance != null) {
    extras.push({ label: "Credits Balance", value: `$${Number(credits.balance).toFixed(2)}` })
  }
  return { id: "codex", name: "Codex", plan: body?.plan_type, windows, extras, fetchedAt: Date.now() }
}

/** Newest `*.jsonl` under ~/.codex/sessions/YYYY/MM/DD. */
async function newestSessionFile(codexHome: string): Promise<string | undefined> {
  let dir = join(codexHome, "sessions")
  for (let depth = 0; depth < 3; depth++) {
    const entries = (await readdir(dir).catch(() => [] as string[])).filter((n) => /^\d+$/.test(n)).sort()
    if (!entries.length) return
    dir = join(dir, entries[entries.length - 1]!)
  }
  const files = (await readdir(dir).catch(() => [] as string[])).filter((n) => n.endsWith(".jsonl"))
  const withTime = await Promise.all(files.map(async (f) => ({ f, t: (await stat(join(dir, f))).mtimeMs })))
  withTime.sort((a, b) => b.t - a.t)
  return withTime[0] && join(dir, withTime[0].f)
}

/** Offline fallback: the latest rate_limits snapshot Codex wrote to its session log. */
async function fromSessions(dir: string): Promise<ProviderUsage> {
  const file = await newestSessionFile(dir)
  if (!file) throw new ProviderError("no Codex usage data yet")
  const lines = (await readFile(file, "utf8")).trimEnd().split("\n")
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!lines[i]!.includes("rate_limits")) continue
    let limits: any
    try {
      const ev = JSON.parse(lines[i]!)
      limits = ev?.payload?.rate_limits ?? ev?.rate_limits
    } catch {
      continue
    }
    if (!limits) continue
    const windows: UsageWindow[] = []
    for (const [w, fallback] of [
      [limits.primary, "5-Hour"],
      [limits.secondary, "Weekly"],
    ] as const) {
      if (!w) continue
      const resetsAt = toMillis(w.resets_at)
      windows.push({
        label: windowLabel(w.window_minutes ? w.window_minutes * 60 : undefined, fallback),
        usedPct: clampPct(w.used_percent),
        // Past resets mean the snapshot is stale for that window.
        resetsAt,
      })
    }
    const extras: UsageExtra[] = []
    if (limits.credits?.balance != null && !limits.credits.unlimited)
      extras.push({ label: "Credits Balance", value: `$${Number(limits.credits.balance).toFixed(2)}` })
    return { id: "codex", name: "Codex", windows, extras, fetchedAt: Date.now() }
  }
  throw new ProviderError("no Codex usage data yet")
}

export const codex: Provider = {
  id: "codex",
  name: "Codex",
  async fetch(signal, profile) {
    const dir = profile ?? home()
    try {
      return await fromApi(dir, signal)
    } catch (e) {
      try {
        return await fromSessions(dir)
      } catch {
        throw e
      }
    }
  },
  async account(profile) {
    const idToken = JSON.parse(await readFile(join(profile ?? home(), "auth.json"), "utf8"))?.tokens?.id_token
    return idToken ? jwtPayload(idToken)?.email : undefined
  },
  // Another account lives in its own folder, e.g. ".codex-2", signed in with CODEX_HOME.
  profiles: () => siblingProfiles(home(), ".codex", "auth.json"),
  detect: async () => existsSync(join(home(), "auth.json")) || (await siblingProfiles(home(), ".codex", "auth.json")).length > 0,
}
