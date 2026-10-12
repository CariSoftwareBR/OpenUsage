import type { KeySpec } from "./keys.ts"

export type ProviderId =
  | "claude"
  | "codex"
  | "copilot"
  | "cursor"
  | "devin"
  | "grok"
  | "kilo"
  | "ollama"
  | "opencode-go"
  | "openrouter"
  | "zai"

/** One rate-limit window, e.g. Claude "5-Hour". */
export interface UsageWindow {
  readonly label: string
  /** 0..100 */
  readonly usedPct: number
  /** Epoch millis when the window resets, if known. */
  readonly resetsAt?: number
}

/** A non-percentage line, e.g. Codex "Credits Balance  $0.00". */
export interface UsageExtra {
  readonly label: string
  readonly value: string
}

export interface ProviderUsage {
  readonly id: ProviderId
  /** Unique per card: the provider id, plus the profile folder for extra accounts, e.g. "claude:.claude-2". */
  readonly key?: string
  readonly name: string
  readonly windows: readonly UsageWindow[]
  readonly extras: readonly UsageExtra[]
  /** Plan name shown next to the provider, e.g. "max", "pro". */
  readonly plan?: string
  /** Signed-in account, usually its email. */
  readonly account?: string
  /** Short, user-facing reason when the provider could not be read. */
  readonly error?: string
  readonly fetchedAt: number
}

export interface Provider {
  readonly id: ProviderId
  readonly name: string
  /** `profile` is a config folder of another signed-in account; omitted means the default one. */
  fetch(signal?: AbortSignal, profile?: string): Promise<ProviderUsage>
  /** Reads the signed-in account from local files only; resolves undefined when unknown. */
  account?(profile?: string): Promise<string | undefined>
  /** Config folders of extra accounts, besides the default one. */
  profiles?(): Promise<string[]>
  /** Whether the tool is set up on this machine: the widget shows the ones it finds. */
  detect(): Promise<boolean>
  /** Services with no CLI login: the key is found on the machine, else pasted in the widget's settings. */
  apiKey?: ApiKeyInfo
}

export interface ApiKeyInfo {
  readonly spec: KeySpec
  /** Where to create a key. */
  readonly url: string
  /** Resolves when the service accepts the key; rejects with the reason otherwise. */
  check(key: string, signal?: AbortSignal): Promise<void>
}

export class ProviderError extends Error {}

export async function getJson(url: string, init: RequestInit, what: string): Promise<any> {
  const res = await fetch(url, { ...init, signal: init.signal ?? AbortSignal.timeout(15_000) })
  if (res.status === 401 || res.status === 403) throw new ProviderError(`${what}: sign in again`)
  if (res.status === 429) throw new ProviderError(`${what}: rate limited, will retry`)
  if (!res.ok) throw new ProviderError(`${what}: HTTP ${res.status}`)
  return res.json()
}

/** First row of a read-only query against a local SQLite file. */
export async function sqliteGet(path: string, sql: string, ...params: unknown[]): Promise<any> {
  const { DatabaseSync } = await import("node:sqlite")
  const db = new DatabaseSync(path, { readOnly: true })
  try {
    return db.prepare(sql).get(...(params as never[]))
  } finally {
    db.close()
  }
}

/**
 * Folders in home named like the default one plus a suffix (e.g. ".claude-2", ".codex-work")
 * that hold `marker`: a second account signed in with CLAUDE_CONFIG_DIR / CODEX_HOME.
 */
export async function siblingProfiles(defaultDir: string, prefix: string, marker: string): Promise<string[]> {
  const { readdir, stat } = await import("node:fs/promises")
  const { homedir } = await import("node:os")
  const { join, resolve } = await import("node:path")
  const home = homedir()
  const names = (await readdir(home).catch(() => [] as string[])).filter((n) => n.startsWith(prefix) && n !== prefix)
  const found: string[] = []
  for (const n of names.sort()) {
    const dir = join(home, n)
    if (resolve(dir).toLowerCase() === resolve(defaultDir).toLowerCase()) continue
    if (await stat(join(dir, marker)).then((s) => s.isFile(), () => false)) found.push(dir)
  }
  return found
}

/** Decodes a JWT payload without verifying it. */
export function jwtPayload(jwt: string): any {
  try {
    return JSON.parse(Buffer.from(jwt.split(".")[1]!, "base64url").toString("utf8"))
  } catch {
    return undefined
  }
}

export function clampPct(n: unknown): number {
  const v = typeof n === "number" ? n : Number(n)
  if (!Number.isFinite(v)) return 0
  return Math.max(0, Math.min(100, v))
}

/** Accepts ISO strings, epoch seconds or epoch millis. */
export function toMillis(v: unknown): number | undefined {
  if (v == null || v === "") return undefined
  if (typeof v === "number") return v < 1e12 ? v * 1000 : v
  const n = Number(v)
  if (Number.isFinite(n)) return toMillis(n)
  const t = Date.parse(String(v))
  return Number.isNaN(t) ? undefined : t
}

export function failed(p: Pick<Provider, "id" | "name">, e: unknown): ProviderUsage {
  const error = e instanceof ProviderError ? e.message : e instanceof Error ? e.message : String(e)
  return { id: p.id, name: p.name, windows: [], extras: [], error, fetchedAt: Date.now() }
}
