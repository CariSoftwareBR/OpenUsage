import { existsSync } from "node:fs"
import { execFile } from "node:child_process"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, getJson, ProviderError, toMillis, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// Undocumented, but it is what the Copilot extensions read for the quota bar.
const USAGE_URL = "https://api.github.com/copilot_internal/user"

const LABELS: Record<string, string> = {
  premium_interactions: "Monthly Premium",
  chat: "Monthly Chat",
  completions: "Monthly Completions",
}

/** Where the Copilot editor plugins keep their sign-in (apps.json / hosts.json). */
const pluginDir = () => {
  if (process.platform === "win32") return join(process.env.LOCALAPPDATA ?? join(homedir(), "AppData", "Local"), "github-copilot")
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "github-copilot")
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "github-copilot")
}

/** GitHub CLI's config folder, whose hosts.yml names the signed-in user. */
const ghDir = () =>
  process.env.GH_CONFIG_DIR ??
  (process.platform === "win32"
    ? join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), "GitHub CLI")
    : join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "gh"))

/** github.com, plus any GitHub Enterprise host the GitHub CLI already has in hosts.yml. */
async function allowedHosts(): Promise<Set<string>> {
  const hosts = new Set<string>(["github.com"])
  const yml = await readFile(join(ghDir(), "hosts.yml"), "utf8").catch(() => "")
  for (const line of yml.split(/\r?\n/)) {
    const name = /^([^ \t#][^:]*):\s*(?:#.*)?$/.exec(line)?.[1]?.trim().toLowerCase()
    if (name && (name === "github.com" || name.includes("."))) hosts.add(name)
  }
  return hosts
}

function hostnameOf(host: string): string | undefined {
  try {
    return new URL(host.includes("://") ? host : `https://${host}`).hostname.toLowerCase()
  } catch {
    return undefined
  }
}

/** Entries of the plugins' apps.json / hosts.json whose host is exactly github.com or a known enterprise host. */
async function pluginLogins(hosts?: ReadonlySet<string>): Promise<Array<{ user?: string; oauth_token?: string }>> {
  const allowed = hosts ?? (await allowedHosts())
  const found = []
  for (const file of ["apps.json", "hosts.json"]) {
    const raw = await readFile(join(pluginDir(), file), "utf8").catch(() => undefined)
    if (!raw) continue
    try {
      for (const [host, v] of Object.entries(JSON.parse(raw) ?? {})) {
        const name = hostnameOf(host)
        if (name && allowed.has(name)) found.push(v as any)
      }
    } catch {}
  }
  return found
}

/** The GitHub CLI's signed-in user, from hosts.yml: "github.com:\n    user: login". */
async function ghUser(): Promise<string | undefined> {
  const yml = await readFile(join(ghDir(), "hosts.yml"), "utf8").catch(() => "")
  return /^github\.com:[\s\S]*?^\s+user:\s*(\S+)/m.exec(yml)?.[1]
}

function ghToken(hostname: string): Promise<string | undefined> {
  return new Promise((resolve) =>
    execFile("gh", ["auth", "token", "--hostname", hostname], { timeout: 10_000, windowsHide: true }, (err, stdout) =>
      resolve(err ? undefined : stdout.trim() || undefined),
    ),
  )
}

/** Plugin tokens first, then `gh auth token` for each known host. A dead plugin token must not hide a working login. */
async function candidateTokens(): Promise<string[]> {
  const hosts = await allowedHosts()
  const tokens: string[] = []
  const add = (token?: string) => {
    const value = token?.trim()
    if (value && !tokens.includes(value)) tokens.push(value)
  }
  for (const login of await pluginLogins(hosts)) add(login.oauth_token)
  for (const host of hosts) add(await ghToken(host))
  return tokens
}

function plan(body: any): string | undefined {
  const sku = String(body?.access_type_sku ?? "")
  if (/plus/i.test(sku)) return "pro+"
  const p = String(body?.copilot_plan ?? "")
  return p === "individual" ? "pro" : p || undefined
}

function usageFrom(body: any): ProviderUsage {
  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  // Paid plans: a snapshot per quota, most of them unlimited.
  const resetsAt = toMillis(body?.quota_reset_date_utc ?? body?.quota_reset_date)
  for (const [key, s] of Object.entries<any>(body?.quota_snapshots ?? {})) {
    if (!s || s.unlimited || !(s.entitlement > 0)) continue
    windows.push({ label: LABELS[key] ?? key, usedPct: clampPct(100 - s.percent_remaining), resetsAt })
    if (key === "premium_interactions") {
      extras.push({ label: "Premium Requests", value: `${Math.max(0, s.entitlement - s.remaining)} / ${s.entitlement}` })
      if (s.overage_count > 0) extras.push({ label: "Overage", value: String(s.overage_count) })
    }
  }
  // Free plan: what is left of each monthly quota.
  const left = body?.limited_user_quotas
  const total = body?.monthly_quotas
  if (left && total) {
    const freeReset = toMillis(body?.limited_user_reset_date)
    for (const key of ["chat", "completions"]) {
      // Some accounts report the same quota in quota_snapshots too.
      if (!(total[key] > 0) || left[key] == null || windows.some((w) => w.label === LABELS[key])) continue
      windows.push({ label: LABELS[key]!, usedPct: clampPct(((total[key] - left[key]) / total[key]) * 100), resetsAt: freeReset })
    }
  }
  if (!windows.length && !extras.length) throw new ProviderError("Copilot: no usage data")
  // The bigger quota first: it is the one the compact ring shows.
  windows.sort((a, b) => (a.label === "Monthly Premium" ? -1 : b.label === "Monthly Premium" ? 1 : 0))
  return {
    id: "copilot",
    name: "Copilot",
    plan: plan(body),
    ...(body?.login ? { account: String(body.login) } : {}),
    windows,
    extras,
    fetchedAt: Date.now(),
  } satisfies ProviderUsage
}

const signedOut = (e: unknown) => e instanceof ProviderError && e.message.includes("sign in again")

export const copilot: Provider = {
  id: "copilot",
  name: "Copilot",
  async fetch(signal) {
    const tokens = await candidateTokens()
    if (!tokens.length) throw new ProviderError("not signed in, run gh auth login")
    let last: unknown
    for (let i = 0; i < tokens.length; i++) {
      try {
        const body = await getJson(
          USAGE_URL,
          {
            signal,
            headers: {
              Authorization: `token ${tokens[i]}`,
              Accept: "application/json",
              "Editor-Version": "vscode/1.100.0",
              "Editor-Plugin-Version": "copilot-chat/0.27.0",
              "User-Agent": "GitHubCopilotChat/0.27.0",
              "X-GitHub-Api-Version": "2025-04-01",
            },
          },
          "Copilot",
        )
        return usageFrom(body)
      } catch (e) {
        last = e
        if (!signedOut(e) || i === tokens.length - 1) throw e
      }
    }
    throw last
  },
  async account() {
    const fromPlugin = (await pluginLogins()).find((l) => l.user)?.user
    return fromPlugin ?? (await ghUser())
  },
  // A sign-in fetch can use: an editor plugin's, or the GitHub CLI's when Copilot is in use here (a plugin or the
  // Copilot CLI has run). Plenty of people have gh without Copilot, and they'd only get an error card.
  async detect() {
    if ((await pluginLogins()).some((l) => l.oauth_token)) return true
    return !!(await ghUser()) && (existsSync(pluginDir()) || existsSync(join(homedir(), ".copilot")))
  },
}
