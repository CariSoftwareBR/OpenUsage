import { existsSync } from "node:fs"
import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, getJson, ProviderError, siblingProfiles, toMillis, type Provider, type ProviderUsage, type UsageWindow } from "./types.ts"

const WINDOWS: ReadonlyArray<readonly [key: string, label: string]> = [
  ["five_hour", "5-Hour"],
  ["seven_day", "7-Day Limit"],
  ["seven_day_opus", "7-Day Opus"],
  ["seven_day_sonnet", "7-Day Sonnet"],
]

const configDir = () => process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude")

/**
 * On macOS Claude Code keeps its login in the Keychain rather than in .credentials.json.
 * A custom config folder gets its own entry, suffixed with a hash of the folder path.
 */
function readKeychain(profile?: string): Promise<string> {
  const dir = profile ?? process.env.CLAUDE_CONFIG_DIR
  const suffix = dir ? `-${createHash("sha256").update(dir).digest("hex").slice(0, 8)}` : ""
  return new Promise((resolve, reject) =>
    execFile(
      "/usr/bin/security",
      ["find-generic-password", "-s", `Claude Code-credentials${suffix}`, "-w"],
      { timeout: 10_000 },
      (err, stdout) => (err ? reject(err) : resolve(stdout.trim())),
    ),
  )
}

async function readCredentials(profile?: string): Promise<string> {
  try {
    return await readFile(join(profile ?? configDir(), ".credentials.json"), "utf8")
  } catch {
    if (process.platform === "darwin") return readKeychain(profile)
    throw new Error("no credentials file")
  }
}

async function readToken(profile?: string) {
  let raw: string
  try {
    raw = await readCredentials(profile)
  } catch {
    throw new ProviderError("not signed in to Claude Code")
  }
  const oauth = JSON.parse(raw)?.claudeAiOauth
  if (!oauth?.accessToken) throw new ProviderError("not signed in to Claude Code")
  // Refreshing here would rotate Claude Code's refresh token, so leave that to Claude Code.
  if (typeof oauth.expiresAt === "number" && oauth.expiresAt < Date.now())
    throw new ProviderError("token expired, open Claude Code")
  return { token: oauth.accessToken as string, plan: oauth.subscriptionType as string | undefined }
}

export const claude: Provider = {
  id: "claude",
  name: "Claude",
  async fetch(signal, profile) {
    const { token, plan } = await readToken(profile)
    const body = await getJson(
      "https://api.anthropic.com/api/oauth/usage",
      {
        signal,
        headers: {
          Authorization: `Bearer ${token}`,
          "anthropic-beta": "oauth-2025-04-20",
          "Content-Type": "application/json",
        },
      },
      "Claude",
    )
    const windows: UsageWindow[] = []
    for (const [key, label] of WINDOWS) {
      const w = body?.[key]
      if (!w || w.utilization == null) continue
      windows.push({ label, usedPct: clampPct(w.utilization), resetsAt: toMillis(w.resets_at) })
    }
    const extras = []
    const extra = body?.extra_usage
    if (extra?.is_enabled && typeof extra.used_credits === "number") {
      extras.push({ label: "Extra Usage", value: `$${(extra.used_credits / 100).toFixed(2)}` })
    }
    return { id: "claude", name: "Claude", plan, windows, extras, fetchedAt: Date.now() } satisfies ProviderUsage
  },
  async account(profile) {
    // Claude Code keeps the signed-in account in .claude.json: inside CLAUDE_CONFIG_DIR when set, else in home.
    const file = profile
      ? join(profile, ".claude.json")
      : process.env.CLAUDE_CONFIG_DIR
        ? join(configDir(), ".claude.json")
        : join(homedir(), ".claude.json")
    const oauth = JSON.parse(await readFile(file, "utf8"))?.oauthAccount
    return oauth?.emailAddress ?? oauth?.displayName
  },
  // Another account lives in its own folder, e.g. ".claude-2", signed in with CLAUDE_CONFIG_DIR.
  profiles: () => siblingProfiles(configDir(), ".claude", ".claude.json"),
  // Claude Code creates its config folder on first run; an extra account alone counts too.
  detect: async () => existsSync(configDir()) || (await siblingProfiles(configDir(), ".claude", ".claude.json")).length > 0,
}
