import { createPrivateKey, createPublicKey, sign } from "node:crypto"
import { mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join } from "node:path"
import { clampPct, ProviderError, toMillis, type Provider, type ProviderUsage, type UsageExtra, type UsageWindow } from "./types.ts"

// Ollama Cloud: https://docs.ollama.com/api/balance
const HOST = "https://ollama.com"

/** Ollama creates this key on first run (also on Windows, under %USERPROFILE%); `ollama signin` links it to the account. */
const keyPath = () => join(homedir(), ".ollama", "id_ed25519")

interface SigningKey {
  /** Base64 SSH wire-format public key, the AAAAC3Nz… body of id_ed25519.pub. */
  publicKey: string
  privateKey: ReturnType<typeof createPrivateKey>
}

/** Reads an unencrypted OpenSSH ed25519 private key ("openssh-key-v1"). */
function parseOpenSshKey(pem: string): SigningKey | undefined {
  const blob = Buffer.from(
    pem
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("-----"))
      .join(""),
    "base64",
  )
  const magic = Buffer.from("openssh-key-v1\0")
  if (!blob.subarray(0, magic.length).equals(magic)) return undefined
  let off = magic.length
  const str = (buf: Buffer) => {
    if (off + 4 > buf.length) return undefined
    const len = buf.readUInt32BE(off)
    if (off + 4 + len > buf.length) return undefined
    const v = buf.subarray(off + 4, off + 4 + len)
    off += 4 + len
    return v
  }
  // Ollama never encrypts it; a passphrase-protected key can't be used.
  if (str(blob)?.toString() !== "none" || str(blob)?.toString() !== "none" || !str(blob)) return undefined
  if (off + 4 > blob.length || blob.readUInt32BE(off) !== 1) return undefined
  off += 4
  const publicBlob = str(blob)
  const priv = str(blob)
  if (!publicBlob || !priv) return undefined
  off = 8 // two check ints
  if (str(priv)?.toString() !== "ssh-ed25519" || !str(priv)) return undefined
  const pair = str(priv)
  if (pair?.length !== 64) return undefined
  const seed = pair.subarray(0, 32)
  // PKCS#8 wrapping of a raw ed25519 seed.
  const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" })
  // A file whose public half doesn't match the private one would sign requests ollama.com rejects.
  const derived = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32)
  if (!derived.equals(pair.subarray(32)) || !publicBlob.subarray(-32).equals(derived)) return undefined
  return { publicKey: publicBlob.toString("base64"), privateKey }
}

async function readKey(): Promise<SigningKey> {
  const pem = await readFile(keyPath(), "utf8").catch(() => undefined)
  if (!pem) throw new ProviderError("no Ollama key, install Ollama and run ollama signin")
  const key = parseOpenSshKey(pem)
  if (!key) throw new ProviderError("~/.ollama/id_ed25519 isn't a usable Ollama key")
  return key
}

/** Signed like the Ollama CLI: "<METHOD>,<path>?ts=<unix seconds>", so a captured header can't be replayed. */
async function call(method: string, path: string, key: SigningKey, signal?: AbortSignal): Promise<Response> {
  const uri = `${path}?ts=${Math.floor(Date.now() / 1000)}`
  const signature = sign(null, Buffer.from(`${method},${uri}`), key.privateKey).toString("base64")
  return fetch(HOST + uri, {
    method,
    signal: signal ?? AbortSignal.timeout(15_000),
    headers: { Authorization: `${key.publicKey}:${signature}`, Accept: "application/json" },
  })
}

/**
 * The key exists as soon as Ollama runs, whether or not it is linked to an ollama.com account, and someone who
 * only runs local models shouldn't get a sign-in warning. So detection asks ollama.com once whether this key is
 * linked, and remembers the answer for that key (offline restarts keep the card).
 */
const linkedPath = () => join(homedir(), ".config", "openusage", "ollama.json")

async function rememberLinked(key: SigningKey | undefined): Promise<void> {
  if (!key) return void (await rm(linkedPath(), { force: true }).catch(() => {}))
  await mkdir(dirname(linkedPath()), { recursive: true }).catch(() => {})
  await writeFile(linkedPath(), JSON.stringify({ linkedKey: key.publicKey })).catch(() => {})
}

async function isLinked(): Promise<boolean> {
  const key = await readKey().catch(() => undefined)
  if (!key) return false
  const cached = await readFile(linkedPath(), "utf8").then((raw) => JSON.parse(raw)?.linkedKey, () => undefined)
  if (cached === key.publicKey) return true
  const res = await call("POST", "/api/me", key, AbortSignal.timeout(8_000)).catch(() => undefined)
  // An unlinked key still gets 200, with an empty user (all-zero ID, no email).
  const me: any = res?.ok ? await res.json().catch(() => undefined) : undefined
  if (!me?.Email && !/[1-9a-f]/i.test(String(me?.ID ?? "").replace(/-/g, ""))) return false
  await rememberLinked(key)
  return true
}

const num = (v: unknown) => (v == null || v === "" || !Number.isFinite(Number(v)) ? undefined : Number(v))
const usd = (n: number) => `$${n.toFixed(2)}`

export const ollama: Provider = {
  id: "ollama",
  name: "Ollama",
  async fetch(signal) {
    const key = await readKey()
    const [balance, me] = await Promise.all([
      call("GET", "/api/balance", key, signal),
      call("POST", "/api/me", key, signal).then(
        (r): Promise<any> => (r.ok ? r.json() : Promise.resolve(undefined)),
        () => undefined,
      ),
    ])
    if (balance.status === 401 || balance.status === 403) {
      // Signed out since: the card goes away at the next start.
      await rememberLinked(undefined)
      throw new ProviderError("not signed in to Ollama Cloud, run ollama signin")
    }
    if (balance.status === 429) throw new ProviderError("Ollama: rate limited, will retry")
    if (!balance.ok) throw new ProviderError(`Ollama: HTTP ${balance.status}`)
    const body: any = await balance.json()
    const inc = body?.included
    if (!inc || typeof inc !== "object") throw new ProviderError("Ollama: no usage data")

    // Ollama reports what remains: older plans as session/weekly percentages, current ones as a monthly dollar allowance.
    const windows: UsageWindow[] = []
    const extras: UsageExtra[] = []
    for (const [field, label] of [
      ["session", "5-Hour"],
      ["weekly", "Weekly"],
    ] as const) {
      const left = num(inc[field]?.remaining_percent)
      if (left != null) windows.push({ label, usedPct: clampPct(100 - left), resetsAt: toMillis(inc[field].resets_at) })
    }
    const allowance = num(inc.allowance_usd)
    const left = num(inc.balance_usd)
    if (allowance && allowance > 0 && left != null) {
      const used = Math.min(allowance, Math.max(0, allowance - left))
      windows.push({ label: "Monthly", usedPct: clampPct((used / allowance) * 100), resetsAt: toMillis(inc.period?.until) })
      extras.push({ label: "Monthly", value: `${usd(used)} / ${usd(allowance)}` })
    }
    if (!windows.length) throw new ProviderError("Ollama: no usage data")
    const purchased = num(body.purchased?.balance_usd)
    if (purchased != null) extras.push({ label: "Purchased Credits", value: usd(Math.max(0, purchased)) })
    const plan = typeof (me?.Plan ?? me?.plan) === "string" ? String(me.Plan ?? me.plan).trim().toLowerCase() || undefined : undefined
    const email = me?.Email ?? me?.email
    return {
      id: "ollama",
      name: "Ollama",
      ...(plan ? { plan } : {}),
      ...(typeof email === "string" && email ? { account: email } : {}),
      windows,
      extras,
      fetchedAt: Date.now(),
    } satisfies ProviderUsage
  },
  detect: isLinked,
}
