// API keys behind the widgets' Settings, for services with no CLI login (OpenRouter, Z.ai). Prints JSON:
// { keys: [{ id, name, url, source, saved }], error? }   source: where the key in use was found, null when none.
//   (no args)    the current state
//   set <id>     checks the key in OPENUSAGE_KEY with the service and keeps it (env, so it never shows in a process list)
//   remove <id>  forgets the key pasted in settings
import { findKey, removeKey, saveKey } from "../src/providers/keys.ts"
import { PROVIDERS, type Provider } from "../src/providers/index.ts"

const keyed = Object.values(PROVIDERS).filter((p): p is Provider & Required<Pick<Provider, "apiKey">> => !!p.apiKey)

async function state() {
  return Promise.all(
    keyed.map(async (p) => {
      const found = await findKey(p.apiKey.spec).catch(() => undefined)
      return { id: p.id, name: p.name, url: p.apiKey.url, source: found?.source ?? null, saved: !!found?.saved }
    }),
  )
}

async function run(): Promise<string | undefined> {
  const [cmd, id] = process.argv.slice(2)
  if (!cmd) return undefined
  const p = keyed.find((k) => k.id === id)
  if (!p) return `unknown provider: ${id}`
  if (cmd === "remove") return void (await removeKey(p.id))
  if (cmd !== "set") return `unknown command: ${cmd}`
  const key = process.env.OPENUSAGE_KEY?.trim()
  if (!key) return "Paste a key."
  try {
    await p.apiKey.check(key, AbortSignal.timeout(20_000))
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return /TimeoutError|aborted|fetch failed/i.test(msg) ? `Couldn't reach ${p.name}. Check the connection.` : msg.replace(/^[^:]+: /, "")
  }
  await saveKey(p.id, key)
  return undefined
}

const error = await run().catch((e) => String(e?.message ?? e))
process.stdout.write(JSON.stringify({ keys: await state(), ...(error ? { error } : {}) }))
