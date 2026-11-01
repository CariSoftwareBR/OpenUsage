// Removes an extra Claude or Codex account added with scripts/add-account.ts: its config folder in home
// (with its sign-in) and the command that opens it (e.g. "claude2"). The main account is never touched.
// Usage: npm run remove-account -- <claude|codex> <command-name|folder>   e.g. claude claude2, codex .codex-work
//        --list   the extra accounts as JSON, for the widgets: [{ kind, folder, account, commands }]
//        --json   with a removal: prints { removed, commands, error } instead of text.
import { readdirSync, readFileSync, renameSync, rmSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { basename, dirname, extname, join, resolve } from "node:path"
import { PROVIDERS } from "../src/providers/index.ts"
import { accountDir, isKind, isWin, type Kind, KINDS, mainDir, pathDirs, which } from "./account-kinds.ts"

const same = (a: string, b: string) => (isWin ? resolve(a).toLowerCase() === resolve(b).toLowerCase() : resolve(a) === resolve(b))

/** The folder a command written by add-account.ts points at, or undefined when the file is something else. */
function shimTarget(kind: Kind, file: string): string | undefined {
  try {
    if (statSync(file).size > 1024) return undefined
    const text = readFileSync(file, "utf8")
    const v = KINDS[kind].envVar
    const m = isWin
      ? new RegExp(`^set "${v}=(.+)"\\r?$`, "m").exec(text)
      : new RegExp(`^${v}='((?:[^']|'\\\\'')*)' exec `, "m").exec(text)
    return m ? (isWin ? m[1] : m[1]!.replace(/'\\''/g, "'")) : undefined
  } catch {
    return undefined
  }
}

/** Every command that opens `dir`: looked for next to the real command and everywhere on PATH. */
function commandsFor(kind: Kind, dir: string): string[] {
  const real = which(KINDS[kind].command)
  const dirs = [...(real ? [dirname(real)] : []), join(homedir(), ".local", "bin"), ...pathDirs()]
  const seen = new Set<string>()
  const found: string[] = []
  for (const d of dirs) {
    const key = isWin ? resolve(d).toLowerCase() : resolve(d)
    if (seen.has(key)) continue
    seen.add(key)
    let names: string[]
    try {
      names = readdirSync(d)
    } catch {
      continue
    }
    for (const n of names) {
      if (isWin && extname(n).toLowerCase() !== ".cmd") continue
      const file = join(d, n)
      const target = shimTarget(kind, file)
      if (target && same(target, dir)) found.push(file)
    }
  }
  return found
}

const commandName = (file: string) => basename(file, isWin ? extname(file) : "")

/** The extra account folders the widgets show, with their account and commands. */
async function list() {
  const out: { kind: Kind; folder: string; account?: string; commands: string[] }[] = []
  for (const kind of Object.keys(KINDS) as Kind[]) {
    const p = PROVIDERS[kind]
    for (const dir of (await p.profiles?.().catch(() => [])) ?? []) {
      const account = await p.account?.(dir).catch(() => undefined)
      const commands = commandsFor(kind, dir).map(commandName)
      out.push({ kind, folder: basename(dir), ...(account ? { account } : {}), commands: [...new Set(commands)] })
    }
  }
  return out
}

/**
 * "claude2", "claude-work", ".claude-2" or a full path -> the account folder in home; undefined when it isn't one.
 * Any extra folder the widgets show counts (also ones made by hand, like ".claude2"), and so does a leftover
 * ".claude-<name>" from add-account.ts; never the main account's folder.
 */
async function resolveDir(kind: Kind, arg: string): Promise<string | undefined> {
  const k = KINDS[kind]
  const home = homedir()
  const profiles = (await PROVIDERS[kind].profiles?.().catch(() => [])) ?? []
  const asPath = arg.startsWith(".") || /[\\/]/.test(arg) ? resolve(home, arg) : undefined
  const dir = asPath ?? commandTarget(kind, arg) ?? accountDir(kind, arg)
  if (!dir || !same(dirname(dir), home) || same(dir, mainDir(kind))) return undefined
  if (profiles.some((p) => same(p, dir))) return dir
  const name = basename(dir).toLowerCase()
  return name.startsWith(`${k.prefix}-`) && name.length > k.prefix.length + 1 ? dir : undefined
}

/** The folder an existing command (e.g. "claude2") opens, whatever its folder is called. */
function commandTarget(kind: Kind, name: string): string | undefined {
  const file = which(name)
  return file ? shimTarget(kind, file) : undefined
}

async function remove(kind: Kind, arg: string): Promise<{ removed?: string; commands: string[]; error?: string }> {
  const k = KINDS[kind]
  const dir = await resolveDir(kind, arg)
  if (!dir) return { commands: [], error: `${arg} is not an extra ${k.name} account.` }
  const shims = commandsFor(kind, dir)
  let exists = true
  try {
    exists = statSync(dir).isDirectory()
  } catch {
    exists = false
  }
  if (!exists && !shims.length) return { commands: [], error: `There is no ${k.name} account in ~/${basename(dir)}.` }

  if (exists) {
    // Moving the folder aside first fails while that account is still open, before anything is deleted.
    const aside = join(homedir(), `.openusage-removing-${basename(dir)}-${Date.now()}`)
    try {
      renameSync(dir, aside)
    } catch {
      const cmd = shims.length ? commandName(shims[0]!) : k.command
      return { commands: [], error: `~/${basename(dir)} is in use. Close ${cmd} and try again.` }
    }
    try {
      rmSync(aside, { recursive: true, force: true, maxRetries: 3 })
    } catch {
      // Already out of the providers' sight; whatever is left is just a stray folder.
    }
  }
  const removed: string[] = []
  for (const s of shims) {
    try {
      rmSync(s, { force: true })
      removed.push(commandName(s))
    } catch {}
  }
  return { removed: basename(dir), commands: removed }
}

async function main() {
  const args = process.argv.slice(2)
  if (args[0] === "--list") {
    process.stdout.write(JSON.stringify(await list()))
    return 0
  }
  const json = args.includes("--json")
  const [kindArg, name] = args.filter((a) => a !== "--json")
  if (!isKind(kindArg) || !name) {
    console.error("Usage: npm run remove-account -- <claude|codex> <command-name|folder>")
    return 2
  }
  const r = await remove(kindArg, name.trim())
  if (json) process.stdout.write(JSON.stringify(r))
  else if (r.error) console.error(r.error)
  else console.log(`Removed ~/${r.removed}${r.commands.length ? ` and the command ${r.commands.join(", ")}` : ""}.`)
  return r.error ? 1 : 0
}

process.exitCode = await main()
