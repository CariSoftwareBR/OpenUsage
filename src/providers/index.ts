import { basename } from "node:path"
import { claude } from "./claude.ts"
import { codex } from "./codex.ts"
import { copilot } from "./copilot.ts"
import { cursor } from "./cursor.ts"
import { kilo } from "./kilo.ts"
import { opencodeGo } from "./opencode-go.ts"
import { failed, type Provider, type ProviderId, type ProviderUsage } from "./types.ts"

export * from "./types.ts"

export const PROVIDERS: Readonly<Record<ProviderId, Provider>> = { claude, codex, copilot, cursor, kilo, "opencode-go": opencodeGo }

/** Never rejects: a failing provider comes back with `error` set. */
export async function fetchUsage(id: ProviderId, signal?: AbortSignal, profile?: string): Promise<ProviderUsage> {
  const p = PROVIDERS[id]
  const [usage, account] = await Promise.all([
    p.fetch(signal, profile).catch((e) => failed(p, e)),
    p.account?.(profile).catch(() => undefined),
  ])
  const key = profile ? `${id}:${basename(profile)}` : id
  // Without a known account, the folder name is what tells two cards apart.
  const name = profile && !account ? `${usage.name} (${basename(profile)})` : usage.name
  return { ...usage, key, name, ...(account ? { account } : {}) }
}

/** One result per signed-in account: the default one first, then any extra profiles. */
export async function fetchAllUsage(id: ProviderId, signal?: AbortSignal): Promise<ProviderUsage[]> {
  const profiles = (await PROVIDERS[id].profiles?.().catch(() => [])) ?? []
  const all = await Promise.all([fetchUsage(id, signal), ...profiles.map((dir) => fetchUsage(id, signal, dir))])
  // The same account copied into two folders shows up once.
  const seen = new Set<string>()
  return all.filter((u, i) => {
    if (i > 0 && u.error && !u.account) return false
    if (!u.account) return true
    const a = u.account.toLowerCase()
    return seen.has(a) ? false : (seen.add(a), true)
  })
}
