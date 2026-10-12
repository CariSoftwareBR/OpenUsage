import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, getJson, ProviderError, sqliteGet, toMillis, type Provider, type ProviderUsage, type UsageWindow } from "./types.ts"

// Undocumented, but it is what the OpenCode console reads: https://github.com/anomalyco/opencode/issues/50804
const USAGE_URL = "https://opencode.ai/zen/go/v1/usage"

const WINDOWS: ReadonlyArray<readonly [key: string, label: string]> = [
  ["rolling", "5-Hour"],
  ["weekly", "Weekly"],
  ["monthly", "Monthly"],
]

const dataDir = () =>
  join(process.env.XDG_DATA_HOME ?? join(homedir(), ".local", "share"), "opencode")

/** The Go API key: env var, else what `/connect` stored in opencode (v2 DB, then v1 auth.json). */
async function readKey(): Promise<string> {
  if (process.env.OPENCODE_GO_API_KEY) return process.env.OPENCODE_GO_API_KEY
  const db = join(dataDir(), "opencode.db")
  if (existsSync(db)) {
    const row = await sqliteGet(
      db,
      "SELECT value FROM credential WHERE integration_id = 'opencode-go' ORDER BY active DESC, time_updated DESC",
    ).catch(() => undefined)
    const key = keyOf(row?.value)
    if (key) return key
  }
  const auth = await readFile(join(dataDir(), "auth.json"), "utf8").catch(() => undefined)
  const key = auth && keyOf(JSON.parse(auth)?.["opencode-go"])
  if (key) return key
  throw new ProviderError("no OpenCode Go key, run /connect in opencode")
}

function keyOf(v: unknown): string | undefined {
  try {
    const cred = typeof v === "string" ? JSON.parse(v) : v
    return (cred as any)?.key ?? (cred as any)?.access
  } catch {
    return undefined
  }
}

export const opencodeGo: Provider = {
  id: "opencode-go",
  name: "OpenCode Go",
  async fetch(signal) {
    const body = await getJson(
      USAGE_URL,
      { signal, headers: { Authorization: `Bearer ${await readKey()}`, Accept: "application/json" } },
      "OpenCode Go",
    )
    const usage = body?.usage ?? body
    const windows: UsageWindow[] = []
    for (const [key, label] of WINDOWS) {
      const w = usage?.[key]
      if (!w || w.percent == null) continue
      windows.push({ label, usedPct: clampPct(w.percent), resetsAt: toMillis(w.resetsAt) })
    }
    if (!windows.length) throw new ProviderError("OpenCode Go: no usage data")
    return { id: "opencode-go", name: "OpenCode Go", plan: "go", windows, extras: [], fetchedAt: Date.now() } satisfies ProviderUsage
  },
  detect: () => readKey().then(() => true, () => false),
}
