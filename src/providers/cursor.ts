import { spawn } from "node:child_process"
import { createDecipheriv } from "node:crypto"
import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import {
  clampPct,
  getJson,
  jwtPayload,
  ProviderError,
  sqliteGet,
  toMillis,
  type Provider,
  type ProviderUsage,
  type UsageExtra,
  type UsageWindow,
} from "./types.ts"

function userDataDir() {
  if (process.platform === "win32") return process.env.APPDATA ?? join(homedir(), "AppData", "Roaming")
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support")
  return process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config")
}

function dbPath() {
  return join(userDataDir(), "Cursor", "User", "globalStorage", "state.vscdb")
}

/** Plaintext session saved by the Cursor CLI and cursor-agent. The editor keeps its own copy in state.vscdb. */
function agentAuthPath() {
  if (process.platform === "win32") return join(userDataDir(), "Cursor", "auth.json")
  if (process.platform === "darwin") return join(homedir(), ".cursor", "auth.json")
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "cursor", "auth.json")
}

/** Reads one value from Cursor's VS Code state DB. */
async function readStateValue(key: string): Promise<string | undefined> {
  const path = dbPath()
  if (!existsSync(path)) throw new ProviderError("Cursor is not installed")
  const v = (await sqliteGet(path, "SELECT value FROM ItemTable WHERE key = ?", key))?.value
  if (v == null) return undefined
  const s = typeof v === "string" ? v : new TextDecoder().decode(v as Uint8Array)
  return s.startsWith('"') ? JSON.parse(s) : s
}

function jwtSubject(jwt: string): string | undefined {
  const sub = String(jwtPayload(jwt)?.sub ?? "")
  return sub.includes("|") ? sub.split("|").pop() : sub || undefined
}

const SAFE_PREFIX = "cursor-safe-storage:v1:"

function run(command: string, args: string[], input?: string, timeout = 15_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] })
    const out: Buffer[] = []
    const err: Buffer[] = []
    let settled = false
    let timer: ReturnType<typeof setTimeout>
    const finish = (fn: () => void) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      fn()
    }
    timer = setTimeout(() => {
      child.kill()
      finish(() => reject(new Error(`${command} timed out`)))
    }, timeout)
    child.stdout?.on("data", (chunk: Buffer) => out.push(chunk))
    child.stderr?.on("data", (chunk: Buffer) => err.push(chunk))
    child.on("error", (error) => finish(() => reject(error)))
    child.on("close", (code) =>
      finish(() =>
        code === 0
          ? resolve(Buffer.concat(out).toString("utf8"))
          : reject(new Error(Buffer.concat(err).toString("utf8").trim() || `${command} exited ${code}`)),
      ),
    )
    child.stdin?.end(input ?? "")
  })
}

/** Chromium OSCrypt key from Cursor's Local State. Current-user DPAPI, then AES-256-GCM. */
let windowsKey: Promise<Buffer> | undefined
function windowsAesKey(): Promise<Buffer> {
  windowsKey ??= loadWindowsAesKey().catch((error) => {
    windowsKey = undefined
    throw error
  })
  return windowsKey
}

async function loadWindowsAesKey(): Promise<Buffer> {
  const local = JSON.parse(await readFile(join(userDataDir(), "Cursor", "Local State"), "utf8"))
  const raw = Buffer.from(String(local?.os_crypt?.encrypted_key ?? ""), "base64")
  if (raw.subarray(0, 5).toString("latin1") !== "DPAPI") throw new Error("no DPAPI key")
  const ps = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$bytes = [Convert]::FromBase64String([Console]::In.ReadToEnd().Trim())
$plain = [System.Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
[Console]::Out.Write([Convert]::ToBase64String($plain))
`
  const out = (await run("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", ps], raw.subarray(5).toString("base64")))
    .replace(/^\uFEFF/, "")
    .trim()
  const key = Buffer.from(out, "base64")
  if (key.length !== 32) throw new Error("bad key")
  return key
}

function decryptGcm(blob: Buffer, key: Buffer): string {
  if (blob.subarray(0, 3).toString("latin1") !== "v10") throw new Error("envelope")
  const iv = blob.subarray(3, 15)
  const tag = blob.subarray(blob.length - 16)
  const data = blob.subarray(15, blob.length - 16)
  const decipher = createDecipheriv("aes-256-gcm", key, iv)
  decipher.setAuthTag(tag)
  return Buffer.concat([decipher.update(data), decipher.final()]).toString("utf8")
}

/**
 * Cursor 3.x on Windows seals the editor access token as `cursor-safe-storage:v1:`
 * plus an Electron safeStorage blob. A plaintext JWT is returned untouched.
 * macOS and Linux stay on that plaintext path: unlocking there would prompt the
 * Keychain or a secret service on every refresh.
 */
async function unlockToken(stored: string): Promise<string | undefined> {
  if (!stored.startsWith(SAFE_PREFIX)) return stored
  if (process.platform !== "win32") return undefined
  try {
    const blob = Buffer.from(stored.slice(SAFE_PREFIX.length), "base64")
    return decryptGcm(blob, await windowsAesKey())
  } catch {
    return undefined
  }
}

async function agentToken(): Promise<string | undefined> {
  const text = await readFile(agentAuthPath(), "utf8").catch(() => undefined)
  if (!text) return undefined
  try {
    const token = JSON.parse(text)?.accessToken
    return typeof token === "string" && token ? token : undefined
  } catch {
    return undefined
  }
}

function usable(token: string | undefined): token is string {
  return !!token && !!jwtSubject(token)
}

/** User id from a session JWT or from `google-oauth2|user_…` / `auth0|user_…`. */
function userId(value: string | undefined): string | undefined {
  if (!value) return undefined
  const subject = jwtSubject(value)
  if (subject) return subject
  const id = value.includes("|") ? value.split("|").pop() : value
  return id || undefined
}

/** CLI session for the editor account. A different login must not replace the editor card. */
async function sameAccountAgent(editorUser: string | undefined): Promise<string | undefined> {
  if (!editorUser) return undefined
  const agent = await agentToken()
  return usable(agent) && userId(agent) === editorUser ? agent : undefined
}

const dollars = (cents: number) => `$${(cents / 100).toFixed(2)}`

async function usageSummary(token: string, signal?: AbortSignal) {
  const user = jwtSubject(token)
  if (!user) throw new ProviderError("unrecognized Cursor token")
  return getJson(
    "https://cursor.com/api/usage-summary",
    {
      signal,
      headers: {
        Cookie: `WorkosCursorSessionToken=${user}%3A%3A${token}`,
        Accept: "application/json",
        Origin: "https://cursor.com",
        Referer: "https://cursor.com/dashboard",
      },
    },
    "Cursor",
  )
}

function toUsage(body: any): ProviderUsage {
  const windows: UsageWindow[] = []
  const extras: UsageExtra[] = []
  const resetsAt = toMillis(body?.billingCycleEnd)
  const plan = body?.individualUsage?.plan
  if (plan?.enabled !== false && plan) {
    const pct =
      typeof plan.totalPercentUsed === "number"
        ? plan.totalPercentUsed
        : plan.limit
          ? (plan.used / plan.limit) * 100
          : 0
    windows.push({ label: "Billing Cycle", usedPct: clampPct(pct), resetsAt })
    // totalPercentUsed is measured against plan + bonus, so show the combined spend.
    const b = plan.breakdown
    if (typeof b?.total === "number" && b.bonus > 0)
      extras.push({ label: "Used", value: `${dollars(b.total)} (${dollars(b.bonus)} bonus)` })
    else if (typeof plan.used === "number" && typeof plan.limit === "number" && plan.limit > 0)
      extras.push({ label: "Included", value: `${dollars(plan.used)} / ${dollars(plan.limit)}` })
  }
  const onDemand = body?.individualUsage?.onDemand
  if (onDemand?.enabled && typeof onDemand.used === "number") {
    const value = onDemand.limit ? `${dollars(onDemand.used)} / ${dollars(onDemand.limit)}` : dollars(onDemand.used)
    extras.push({ label: "On-Demand", value })
  }
  if (!windows.length && !extras.length) throw new ProviderError("Cursor: no usage data")
  return {
    id: "cursor",
    name: "Cursor",
    plan: body?.membershipType,
    windows,
    extras,
    fetchedAt: Date.now(),
  }
}

async function fetchAgentOnly(signal: AbortSignal | undefined, ifMissing: ProviderError): Promise<ProviderUsage> {
  const agent = await agentToken()
  if (!usable(agent)) throw ifMissing
  return toUsage(await usageSummary(agent, signal))
}

/** Sealed editor token. The editor session wins; the CLI is only a same-account fallback. */
async function fetchSealed(stored: string, signal?: AbortSignal): Promise<ProviderUsage> {
  const editorUser = userId(await readStateValue("cursorAuth/stripeMembershipAuthId").catch(() => undefined))
  const editor = await unlockToken(stored)
  const tokens = [
    usable(editor) && (!editorUser || userId(editor) === editorUser) ? editor : undefined,
    await sameAccountAgent(editorUser),
  ].filter(usable)
  let last: unknown
  for (let i = 0; i < tokens.length; i++) {
    try {
      return toUsage(await usageSummary(tokens[i]!, signal))
    } catch (error) {
      last = error
      const rejected = error instanceof ProviderError && error.message.includes("sign in again")
      if (!rejected || i === tokens.length - 1) throw error
    }
  }
  if (last instanceof Error) throw last
  throw new ProviderError("could not read the saved sign-in")
}

export const cursor: Provider = {
  id: "cursor",
  name: "Cursor",
  async fetch(signal) {
    let stored: string | undefined
    try {
      stored = await readStateValue("cursorAuth/accessToken")
    } catch (error) {
      // Only a missing database may fall through to the CLI. A locked file or a
      // rejected editor session must surface as itself, not as another login.
      if (error instanceof ProviderError && error.message === "Cursor is not installed") {
        return fetchAgentOnly(signal, error)
      }
      throw error
    }
    // Plain JWT: the original path. No CLI file and no process spawn.
    if (stored && !stored.startsWith(SAFE_PREFIX)) {
      if (!jwtSubject(stored)) throw new ProviderError("unrecognized Cursor token")
      return toUsage(await usageSummary(stored, signal))
    }
    if (stored?.startsWith(SAFE_PREFIX)) return fetchSealed(stored, signal)
    // Editor database present, but nobody is signed in. Don't borrow another login.
    throw new ProviderError("not signed in to Cursor")
  },
  account: () => readStateValue("cursorAuth/cachedEmail"),
  detect: async () => existsSync(dbPath()) || usable(await agentToken()),
}
