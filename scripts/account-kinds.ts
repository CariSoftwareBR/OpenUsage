// What scripts/add-account.ts and scripts/remove-account.ts share: the two kinds of extra account, where their
// folders and commands live, and a `which`.
import { accessSync, constants, statSync } from "node:fs"
import { homedir } from "node:os"
import { delimiter, dirname, join } from "node:path"

export const KINDS = {
  claude: {
    name: "Claude",
    prefix: ".claude",
    envVar: "CLAUDE_CONFIG_DIR",
    command: "claude",
    login: [] as string[],
    hint: "Sign in with the other Claude account, then type /exit.",
  },
  codex: {
    name: "Codex",
    prefix: ".codex",
    envVar: "CODEX_HOME",
    command: "codex",
    login: ["login"],
    hint: "Sign in with the other ChatGPT account in the browser.",
  },
} as const
export type Kind = keyof typeof KINDS

export const isKind = (s: string | undefined): s is Kind => s === "claude" || s === "codex"

/** The main account's folder: what the env var points at (it can be named like an extra one), else ~/.claude or ~/.codex. */
export const mainDir = (kind: Kind) => process.env[KINDS[kind].envVar] || join(homedir(), KINDS[kind].prefix)

export const isWin = process.platform === "win32"
export const pathDirs = () => (process.env.PATH ?? "").split(delimiter).filter(Boolean)

export function isFile(p: string) {
  try {
    return statSync(p).isFile()
  } catch {
    return false
  }
}

export function canWrite(dir: string) {
  try {
    accessSync(dir, constants.W_OK)
    return true
  } catch {
    return false
  }
}

function isExecutable(p: string) {
  try {
    accessSync(p, constants.X_OK)
    return true
  } catch {
    return false
  }
}

/** Full path of a command on PATH, like `which`. */
export function which(name: string): string | undefined {
  const exts = isWin ? ["", ...(process.env.PATHEXT ?? ".COM;.EXE;.BAT;.CMD").split(";")] : [""]
  for (const dir of pathDirs()) {
    for (const ext of exts) {
      const p = join(dir, name + ext)
      if (!isFile(p)) continue
      if (isWin ? ext !== "" : isExecutable(p)) return p
    }
  }
}

/** "claude2" -> ~/.claude-2, "claude-work" -> ~/.claude-work, "work" -> ~/.claude-work. */
export function accountDir(kind: Kind, name: string): string | undefined {
  const k = KINDS[kind]
  let suffix = name.toLowerCase().startsWith(k.command) ? name.slice(k.command.length) : name
  suffix = suffix.replace(/^[-_]+/, "")
  return suffix ? join(homedir(), `${k.prefix}-${suffix}`) : undefined
}

/** Where a new command goes: next to the real one on Windows, ~/.local/bin (when on PATH) elsewhere. */
export function shimDir(real: string): string {
  if (isWin) return dirname(real)
  const local = join(homedir(), ".local", "bin")
  if (pathDirs().includes(local)) return local
  return canWrite(dirname(real)) ? dirname(real) : local
}
