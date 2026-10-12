import { existsSync } from "node:fs"
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

function dbPath() {
  const rel = ["Cursor", "User", "globalStorage", "state.vscdb"]
  if (process.platform === "win32") return join(process.env.APPDATA ?? join(homedir(), "AppData", "Roaming"), ...rel)
  if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", ...rel)
  return join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), ...rel)
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

const dollars = (cents: number) => `$${(cents / 100).toFixed(2)}`

export const cursor: Provider = {
  id: "cursor",
  name: "Cursor",
  async fetch(signal) {
    const token = await readStateValue("cursorAuth/accessToken")
    if (!token) throw new ProviderError("not signed in to Cursor")
    const user = jwtSubject(token)
    if (!user) throw new ProviderError("unrecognized Cursor token")
    const body = await getJson(
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
    } satisfies ProviderUsage
  },
  account: () => readStateValue("cursorAuth/cachedEmail"),
  detect: async () => existsSync(dbPath()),
}
