// API keys for services with no CLI login of their own (OpenRouter, Z.ai). Nothing to type in a terminal:
// the key is picked up from the tools that already use it, else the one pasted in the widget's settings.
import { existsSync } from "node:fs"
import { mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { sqliteGet } from "./types.ts"

export interface KeySource {
  readonly key: string
  /** Where it came from, shown in settings: "OpenCode", "Claude Code", "OPENROUTER_API_KEY"... */
  readonly source: string
  /** Pasted in the widget, so the widget can remove it. */
  readonly saved: boolean
}

export interface KeySpec {
  readonly id: string
  /** Provider ids other tools file the key under (OpenCode, Kilo, Crush). */
  readonly toolIds: readonly string[]
  /** Env vars, most specific first. */
  readonly envs: readonly string[]
  /** Other files holding just the key (JSON with apiKey/api_key/key, or the bare key). */
  readonly files: readonly string[]
  /** Claude Code pointed at this service: ANTHROPIC_BASE_URL on this host, the token beside it. */
  readonly anthropicHost?: string
}

/** Where the key pasted in settings is kept: ~/.config/openusage/<id>.json, on every OS. */
export const savedKeyPath = (id: string) => join(homedir(), ".config", "openusage", `${id}.json`)

const dataHome = () => process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share")
const configHome = () => process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config")

const readJson = (path: string) =>
  readFile(path, "utf8").then(
    (raw) => JSON.parse(raw),
    () => undefined,
  )

/** A literal key; references like "$OPENROUTER_API_KEY" or "{env:X}" are resolved by the env step instead. */
const literal = (v: unknown) => (typeof v === "string" && v.trim() && !/^\$|^\{env:/.test(v.trim()) ? v.trim() : undefined)

async function keyFile(path: string): Promise<string | undefined> {
  const raw = (await readFile(path, "utf8").catch(() => ""))?.trim()
  if (!raw) return undefined
  try {
    const j = JSON.parse(raw)
    return literal(typeof j === "string" ? j : (j?.apiKey ?? j?.api_key ?? j?.key))
  } catch {
    return literal(raw)
  }
}

/** OpenCode and Kilo (a fork of it): `/connect` saves {type:"api", key} per provider, in auth.json or the v2 DB. */
async function fromOpenCodeLike(dir: string, ids: readonly string[]): Promise<string | undefined> {
  const db = join(dir, "opencode.db")
  if (existsSync(db)) {
    const marks = ids.map(() => "?").join(",")
    const row = await sqliteGet(
      db,
      `SELECT value FROM credential WHERE integration_id IN (${marks}) ORDER BY active DESC, time_updated DESC`,
      ...ids,
    ).catch(() => undefined)
    try {
      const key = row?.value && literal(JSON.parse(row.value)?.key)
      if (key) return key
    } catch {}
  }
  const auth = await readJson(join(dir, "auth.json"))
  for (const id of ids) {
    const key = literal(auth?.[id]?.key)
    if (key) return key
  }
  return undefined
}

async function fromOpenCodeConfig(ids: readonly string[]): Promise<string | undefined> {
  for (const name of ["opencode.json", "opencode.jsonc"]) {
    const cfg = await readJson(join(configHome(), "opencode", name))
    for (const id of ids) {
      const key = literal(cfg?.provider?.[id]?.options?.apiKey)
      if (key) return key
    }
  }
  return undefined
}

async function fromCrush(ids: readonly string[]): Promise<string | undefined> {
  for (const path of [join(dataHome(), "crush", "crush.json"), join(configHome(), "crush", "crush.json")]) {
    const cfg = await readJson(path)
    for (const id of ids) {
      const key = literal(cfg?.providers?.[id]?.api_key)
      if (key) return key
    }
  }
  return undefined
}

async function fromClaudeCode(host: string): Promise<string | undefined> {
  const dir = process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")
  const env = (await readJson(join(dir, "settings.json")))?.env
  if (!String(env?.ANTHROPIC_BASE_URL ?? "").includes(host)) return undefined
  return literal(env.ANTHROPIC_AUTH_TOKEN) ?? literal(env.ANTHROPIC_API_KEY)
}

/** The key for this service, from the first place that has one; undefined when none does. */
export async function findKey(spec: KeySpec): Promise<KeySource | undefined> {
  const saved = await keyFile(savedKeyPath(spec.id))
  if (saved) return { key: saved, source: "OpenUsage", saved: true }
  for (const name of spec.envs) {
    const v = literal(process.env[name])
    if (v) return { key: v, source: name, saved: false }
  }
  const steps: Array<[string, () => Promise<string | undefined>]> = [
    ["OpenCode", () => fromOpenCodeLike(join(dataHome(), "opencode"), spec.toolIds)],
    ["OpenCode", () => fromOpenCodeConfig(spec.toolIds)],
    ["Kilo", () => fromOpenCodeLike(join(dataHome(), "kilo"), spec.toolIds)],
    ["Crush", () => fromCrush(spec.toolIds)],
    ...(spec.anthropicHost ? [["Claude Code", () => fromClaudeCode(spec.anthropicHost!)] as [string, () => Promise<string | undefined>]] : []),
    ...spec.files.map((f) => [f.replace(homedir(), "~"), () => keyFile(f)] as [string, () => Promise<string | undefined>]),
  ]
  for (const [source, find] of steps) {
    const key = await find().catch(() => undefined)
    if (key) return { key, source, saved: false }
  }
  return undefined
}

/** Keeps the key pasted in settings, readable by this user only (the profile folder already is, on Windows). */
export async function saveKey(id: string, key: string): Promise<void> {
  const path = savedKeyPath(id)
  await mkdir(dirname(path), { recursive: true })
  await writeFile(path, JSON.stringify({ apiKey: key.trim() }, null, 2) + "\n", { mode: 0o600 })
}

export const removeKey = (id: string) => rm(savedKeyPath(id), { force: true })
