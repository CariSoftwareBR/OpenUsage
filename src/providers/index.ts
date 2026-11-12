import { basename } from "node:path"
import { claude } from "./claude.ts"
import { codex } from "./codex.ts"
import { copilot } from "./copilot.ts"
import { cursor } from "./cursor.ts"
import { devin } from "./devin.ts"
import { grok } from "./grok.ts"
import { kilo } from "./kilo.ts"
import { ollama } from "./ollama.ts"
import { opencodeGo } from "./opencode-go.ts"
import { openrouter } from "./openrouter.ts"
import { zai } from "./zai.ts"
import { failed, ProviderError, type Provider, type ProviderId, type ProviderUsage } from "./types.ts"

export * from "./types.ts"

export const PROVIDERS: Readonly<Record<ProviderId, Provider>> = {
  claude,
  codex,
  copilot,
  cursor,
  kilo,
  "opencode-go": opencodeGo,
  devin,
  grok,
  openrouter,
  zai,
  ollama,
}

/** Never rejects: a failing provider comes back with `error` set. */
export async function fetchUsage(id: ProviderId, signal?: AbortSignal, profile?: string): Promise<ProviderUsage> {
  const p = PROVIDERS[id]
  if (!p) return failed({ id, name: id }, new ProviderError(`unknown provider: ${id}`))
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
  const provider = PROVIDERS[id]
  if (!provider) return []
  const profiles = (await provider.profiles?.().catch(() => [])) ?? []
  const all = await Promise.all([fetchUsage(id, signal), ...profiles.map((dir) => fetchUsage(id, signal, dir))])
  // The same account copied into two folders shows up once, preferring the card that actually loaded.
  // An extra folder that failed before its email could be read stays: profiles() only returns folders with a session file.
  const chosen: ProviderUsage[] = []
  const indexByAccount = new Map<string, number>()
  for (const u of all) {
    if (!u.account) {
      chosen.push(u)
      continue
    }
    const key = u.account.toLowerCase()
    const prev = indexByAccount.get(key)
    if (prev == null) {
      indexByAccount.set(key, chosen.length)
      chosen.push(u)
      continue
    }
    if (chosen[prev]?.error && !u.error) chosen[prev] = u
  }
  return chosen
}
