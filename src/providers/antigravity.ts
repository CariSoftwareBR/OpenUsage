import { readdir, readFile, stat } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { clampPct, ProviderError, toMillis, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// Antigravity keeps no usage on disk: its local language server answers the same GetUserStatus call the app makes.
// Each running server writes ~/.gemini/antigravity/daemon/hub_<port>.json with its pid, port and CSRF token,
// so the limits can be read only while Antigravity is open. Nothing leaves the computer.

const dataDir = () => join(homedir(), ".gemini", "antigravity")
const daemonDir = () => join(dataDir(), "daemon")

function appDir() {
  if (process.platform === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), "Antigravity")
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "Antigravity")
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "Antigravity")
}

interface Hub {
  pid: number
  httpPort: number
  csrfToken: string
  mtime: number
}

const alive = (pid: number) => {
  try {
    process.kill(pid, 0)
    return true
  } catch (e) {
    // EPERM: the process exists but belongs to someone else.
    return (e as NodeJS.ErrnoException).code === "EPERM"
  }
}

/** Servers still running, newest first: the files of closed ones stay behind. */
async function liveHubs(): Promise<Hub[]> {
  const dir = daemonDir()
  const names = (await readdir(dir).catch(() => [] as string[])).filter((n) => /^hub_\d+\.json$/.test(n))
  const hubs: Hub[] = []
  for (const n of names) {
    try {
      const path = join(dir, n)
      const j = JSON.parse(await readFile(path, "utf8"))
      const pid = Number(j.pid)
      const httpPort = Number(j.httpPort)
      if (!pid || !httpPort || typeof j.csrfToken !== "string" || !alive(pid)) continue
      hubs.push({ pid, httpPort, csrfToken: j.csrfToken, mtime: (await stat(path)).mtimeMs })
    } catch {}
  }
  return hubs.sort((a, b) => b.mtime - a.mtime)
}

async function userStatus(hub: Hub, signal?: AbortSignal): Promise<any> {
  const res = await fetch(`http://127.0.0.1:${hub.httpPort}/exa.language_server_pb.LanguageServerService/GetUserStatus`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Connect-Protocol-Version": "1", "X-Codeium-Csrf-Token": hub.csrfToken },
    body: JSON.stringify({ metadata: { ideName: "antigravity", extensionName: "antigravity", locale: "en" } }),
    signal: signal ?? AbortSignal.timeout(10_000),
  })
  if (!res.ok) throw new ProviderError(`Antigravity: HTTP ${res.status}`)
  const status = ((await res.json()) as any)?.userStatus
  if (!status) throw new ProviderError("Antigravity: not signed in")
  return status
}

/**
 * Models draw on shared pools: each Gemini model across its thinking levels ("Gemini 3.8 Flash (High)", "(Low)"...),
 * and the Claude and GPT-OSS models together. A pool shows its most used model and its soonest reset.
 */
function poolOf(label: string): string {
  const base = label.replace(/\s*\([^)]*\)\s*$/, "").trim()
  return /^gemini\b/i.test(base) ? base : "Claude / GPT"
}

function windowsOf(status: any): UsageWindow[] {
  const pools = new Map<string, UsageWindow>()
  for (const c of status?.cascadeModelConfigData?.clientModelConfigs ?? []) {
    const q = c?.quotaInfo
    if (c?.disabled || !q || q.remainingFraction == null || !c.label) continue
    const label = poolOf(String(c.label))
    const usedPct = clampPct((1 - Number(q.remainingFraction)) * 100)
    const resetsAt = toMillis(q.resetTime)
    const prev = pools.get(label)
    const resets = [prev?.resetsAt, resetsAt].filter((t): t is number => t != null)
    pools.set(label, {
      label,
      usedPct: Math.max(prev?.usedPct ?? 0, usedPct),
      ...(resets.length ? { resetsAt: Math.min(...resets) } : {}),
    })
  }
  return [...pools.values()]
}

/** "g1-pro-tier" -> "pro"; else the plan name the server reports. */
function planOf(status: any): string | undefined {
  const tier = String(status?.userTier?.id ?? "").match(/^g1-([a-z]+)-tier$/)?.[1]
  const name = tier ?? status?.planStatus?.planInfo?.planName
  return name ? String(name).toLowerCase() : undefined
}

function extrasOf(status: any): UsageExtra[] {
  const extras: UsageExtra[] = []
  for (const c of status?.userTier?.availableCredits ?? []) {
    const amount = c?.creditAmount ?? c?.availableCreditAmount
    if (amount != null) extras.push({ label: "AI Credits", value: Number(amount).toLocaleString("en-US") })
  }
  return extras
}

export const antigravity: Provider = {
  id: "antigravity",
  name: "Antigravity",
  async fetch(signal) {
    const hubs = await liveHubs()
    if (!hubs.length) throw new ProviderError("open Antigravity to read its limits")
    let status: any
    let lastError: unknown
    for (const hub of hubs) {
      try {
        status = await userStatus(hub, signal)
        break
      } catch (e) {
        lastError = e
      }
    }
    if (!status) throw lastError instanceof ProviderError ? lastError : new ProviderError("open Antigravity to read its limits")
    const windows = windowsOf(status)
    const extras = extrasOf(status)
    if (!windows.length && !extras.length) throw new ProviderError("Antigravity: no usage data")
    const plan = planOf(status)
    return {
      id: "antigravity",
      name: "Antigravity",
      ...(plan ? { plan } : {}),
      ...(status.email ? { account: String(status.email) } : {}),
      windows,
      extras,
      fetchedAt: Date.now(),
    } satisfies ProviderUsage
  },
  // The account the app last signed in with, so the card is named even while Antigravity is closed.
  async account() {
    const raw = await readFile(join(appDir(), "app_storage.json"), "utf8").catch(() => undefined)
    if (!raw) return undefined
    let v = JSON.parse(raw)?.["jetski.onboarding.lastLoginUsername"]
    if (typeof v === "string" && v.startsWith('"')) v = JSON.parse(v)
    return typeof v === "string" && v.includes("@") ? v : undefined
  },
  detect: () => stat(dataDir()).then((s) => s.isDirectory(), () => false),
}
