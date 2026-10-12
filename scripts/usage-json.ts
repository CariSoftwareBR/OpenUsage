// Prints every provider's usage as one JSON array. Used by the desktop widget.
// No ids: the providers set up on this machine. --detect: just their ids, without fetching anything.
import { fetchAllUsage, PROVIDERS, type ProviderId } from "../src/providers/index.ts"

const detected = async () => {
  const all = Object.keys(PROVIDERS) as ProviderId[]
  const found = await Promise.all(all.map((id) => PROVIDERS[id].detect().catch(() => false)))
  return all.filter((_, i) => found[i])
}

const args = process.argv.slice(2)
if (args[0] === "--detect") {
  process.stdout.write(JSON.stringify(await detected()))
} else {
  const ids = (args.length ? args : await detected()) as ProviderId[]
  process.stdout.write(JSON.stringify((await Promise.all(ids.map((id) => fetchAllUsage(id)))).flat()))
}
