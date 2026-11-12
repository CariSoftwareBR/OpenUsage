// Prints every provider's usage as one JSON array. Used by the desktop widget.
// No ids: the providers set up on this machine. --detect: just their ids, without fetching anything.
import { failed, fetchAllUsage, PROVIDERS, type ProviderId } from "../src/providers/index.ts"

const detected = async () => {
  const all = Object.keys(PROVIDERS) as ProviderId[]
  const found = await Promise.all(all.map((id) => PROVIDERS[id].detect().catch(() => false)))
  return all.filter((_, i) => found[i])
}

const args = process.argv.slice(2)
if (args[0] === "--detect") {
  process.stdout.write(JSON.stringify(await detected()))
} else {
  const requested = args.length ? args : await detected()
  const ids = requested.filter((id): id is ProviderId => id in PROVIDERS)
  const rows = await Promise.all(ids.map((id) => fetchAllUsage(id).catch((e) => [failed(PROVIDERS[id], e)])))
  process.stdout.write(JSON.stringify(rows.flat()))
}
