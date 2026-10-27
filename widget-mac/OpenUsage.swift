// Floating Claude / Codex / Cursor / OpenCode Go usage widget for macOS.
// Plain AppKit + SwiftUI, compiled on the user's Mac by build.sh: nothing to download.
// Data comes from ../scripts/usage-json.ts, run with Node (>= 22.6).

import AppKit
import Combine
import SwiftUI

let refreshMinutes = 5.0
let bundleId = "com.openusage.widget"
let showNotification = Notification.Name("com.openusage.widget.show")
let icons = [
  "claude": "\u{273B}", "codex": "\u{25CE}", "copilot": "\u{25C8}", "cursor": "\u{2B21}", "devin": "\u{25C7}", "grok": "\u{2726}",
  "kilo": "\u{25C6}", "ollama": "\u{25C9}", "opencode-go": "\u{25A3}", "openrouter": "\u{21C4}", "zai": "\u{25B2}",
]

// ---- data ----------------------------------------------------------------------

struct UsageWindow: Codable {
  var label: String
  var usedPct: Double
  var resetsAt: Double?
}

struct UsageExtra: Codable {
  var label: String
  var value: String
}

struct ProviderUsage: Codable {
  var id: String
  /** One per account; missing in caches written before multi-account support. */
  var key: String?
  var uid: String { key ?? id }
  var name: String
  var windows: [UsageWindow]
  var extras: [UsageExtra]
  var plan: String?
  var account: String?
  var error: String?
  var fetchedAt: Double
}

/** What scripts/update.ts prints. */
/** An API key of a service with no CLI sign-in (OpenRouter, Z.ai), as scripts/keys.ts reports it. */
struct KeyInfo: Codable {
  let id: String
  let name: String
  let url: String
  let source: String?
  let saved: Bool
}

struct KeysResult: Codable {
  let keys: [KeyInfo]
  let error: String?
}

let keyedProviders = ["openrouter", "zai"]

struct ProviderName {
  let id: String
  let name: String
}

/** Every provider the widget offers, in the order the settings list them. */
let providerNames = [
  ("claude", "Claude"), ("codex", "Codex"), ("copilot", "Copilot"), ("cursor", "Cursor"), ("devin", "Devin"),
  ("grok", "Grok"), ("kilo", "Kilo"), ("ollama", "Ollama"), ("opencode-go", "OpenCode Go"),
  ("openrouter", "OpenRouter"), ("zai", "Z.ai"),
].map { ProviderName(id: $0.0, name: $0.1) }

/** "No key yet", "Saved here", "Found in OpenCode", "From OPENROUTER_API_KEY". */
func keyStatus(_ k: KeyInfo?) -> String {
  guard let k else { return "Looking for a key..." }
  guard let source = k.source else { return "No key yet" }
  if k.saved { return "Saved here" }
  if source == source.uppercased() || source.contains("/") { return "From \(source)" }
  return "Found in \(source)"
}

struct UpdateInfo: Codable {
  var version: String?
  var commit: String?
  var behind: Int?
  var error: String?
  var updated: Bool?
}

struct UpdateState {
  var busy = ""
  var version = ""
  var commit = ""
  var behind = 0
  var error = ""
  var checked = false
}

struct Cache: Codable {
  var updatedAt: Double?
  var data: [ProviderUsage]
}

/** Files build.sh writes into the bundle: where the repo lives and which node to run. */
func resource(_ name: String) -> String? {
  guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
    let s = try? String(contentsOf: url, encoding: .utf8)
  else { return nil }
  let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
  return t.isEmpty ? nil : t
}

let stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("usage-widget")
let cacheURL = stateDir.appendingPathComponent("data.json")
let defaults = UserDefaults.standard

final class Model: ObservableObject {
  @Published var data: [ProviderUsage] = []
  @Published var updatedAt: Double?
  @Published var refreshing = false
  @Published var lastError = ""
  @Published var display = defaults.string(forKey: "display") ?? "used"
  @Published var layout = ["compact", "bar"].contains(defaults.string(forKey: "layout") ?? "") ? defaults.string(forKey: "layout")! : "normal"
  /** How compact and strip draw a limit: "ring" or "bar" (a slim meter). */
  @Published var gauge = defaults.string(forKey: "gauge") == "bar" ? "bar" : "ring"
  @Published var update = UpdateState()
  @Published var keys: [String: KeyInfo] = [:]
  /**
   * Providers switched off: not fetched and not shown. At the first start only the ones set up on this Mac are on;
   * "seen" remembers which were found, so one installed later turns on by itself and one switched off stays off.
   */
  @Published var hiddenProviders = defaults.stringArray(forKey: "hiddenProviders") ?? []
  private var seenProviders = defaults.stringArray(forKey: "seenProviders")
  /** Providers this widget offered at the last detection: one added by an update starts off unless it is found here. */
  private var knownProviders: [String]
  private var detectProc: Process?
  /** Asked for while a refresh was running (a provider switched back on, say): fetch again when it ends. */
  private var refreshPending = false

  private var proc: Process?
  private var updateProc: Process?
  private var keysProc: Process?

  init() {
    knownProviders =
      defaults.stringArray(forKey: "knownProviders")
      ?? ((defaults.stringArray(forKey: "seenProviders") ?? []) + (defaults.stringArray(forKey: "hiddenProviders") ?? []))
    // The last good result is cached on disk, so a restart (or a rate-limited first fetch) still shows numbers.
    if let raw = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: raw) {
      data = cache.data
      updatedAt = cache.updatedAt
    }
  }

  func toggleDisplay() { setDisplay(display == "used" ? "remaining" : "used") }

  func setDisplay(_ v: String) {
    display = v
    defaults.set(v, forKey: "display")
  }

  func setLayout(_ v: String) {
    layout = v
    defaults.set(v, forKey: "layout")
  }

  func setGauge(_ v: String) {
    gauge = v
    defaults.set(v, forKey: "gauge")
  }

  /** Runs scripts/<name> with node and hands its stdout to `done` on the main thread; nil when it can't start. */
  func runScript(
    _ name: String, _ args: [String], timeout: Double, env: [String: String] = [:], done: @escaping (Data, Bool) -> Void
  ) -> Process? {
    guard let root = resource("root") else { return nil }
    let script = root + "/scripts/" + name
    let p = Process()
    // Apps started from Finder do not get the shell's PATH, so prefer the node build.sh found.
    if let node = resource("node"), FileManager.default.isExecutableFile(atPath: node) {
      p.executableURL = URL(fileURLWithPath: node)
      p.arguments = ["--experimental-strip-types", "--no-warnings", script] + args
    } else {
      p.executableURL = URL(fileURLWithPath: "/bin/zsh")
      p.arguments = ["-lc", "exec node --experimental-strip-types --no-warnings \"$0\" \"$@\"", script] + args
    }
    p.currentDirectoryURL = URL(fileURLWithPath: root)
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do {
      try p.run()
    } catch {
      return nil
    }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    // Read on a background thread so a full pipe never blocks the child.
    DispatchQueue.global().async {
      let raw = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      killer.cancel()
      DispatchQueue.main.async { done(raw, p.terminationReason == .uncaughtSignal) }
    }
    return p
  }

  func refresh() {
    // While the providers are being detected the switches aren't settled yet; detection refreshes when done.
    guard detectProc == nil else { return }
    guard proc == nil else {
      refreshPending = true
      return
    }
    guard resource("root") != nil else {
      lastError = "run build.sh again"
      return
    }
    let ids = providerNames.map(\.id).filter { !hiddenProviders.contains($0) }
    // Nothing switched on: no ids would mean "whatever is set up" to the script, so don't ask at all.
    if ids.isEmpty {
      data = []
      return
    }
    proc = runScript("usage-json.ts", ids, timeout: 60) { raw, timedOut in
      self.complete(raw, timedOut: timedOut)
      if self.refreshPending {
        self.refreshPending = false
        self.refresh()
      }
    }
    if proc == nil {
      lastError = "node not found"
      return
    }
    refreshing = true
  }

  /** Asks which providers are set up on this Mac (local files only, no network), then refreshes. */
  func detect() {
    guard detectProc == nil else { return }
    detectProc = runScript("usage-json.ts", ["--detect"], timeout: 30) { raw, _ in
      self.detectProc = nil
      self.refreshing = false
      // A run that failed (or printed nothing) found nothing out: leave the switches as they are.
      if let found = try? JSONDecoder().decode([String].self, from: raw) {
        let all = providerNames.map(\.id)
        if let seen = self.seenProviders {
          let new = found.filter { !seen.contains($0) }
          let unknown = all.filter { !self.knownProviders.contains($0) && !found.contains($0) }
          var hidden = self.hiddenProviders.filter { !new.contains($0) }
          for id in unknown where !hidden.contains(id) { hidden.append(id) }
          self.hiddenProviders = hidden
          self.seenProviders = seen + new
        } else {
          self.hiddenProviders = all.filter { !found.contains($0) }
          self.seenProviders = found
        }
        self.knownProviders = all
        defaults.set(self.hiddenProviders, forKey: "hiddenProviders")
        defaults.set(self.seenProviders, forKey: "seenProviders")
        defaults.set(self.knownProviders, forKey: "knownProviders")
      }
      self.refresh()
    }
    if detectProc == nil { refresh() } else { refreshing = true }
  }

  /** Switches a provider on or off; one switched back on has nothing cached, so it is fetched. */
  func setProvider(_ id: String, on: Bool) {
    hiddenProviders.removeAll { $0 == id }
    if !on { hiddenProviders.append(id) }
    defaults.set(hiddenProviders, forKey: "hiddenProviders")
    if on { refresh() }
  }

  /**
   * scripts/keys.ts: no args reads which keys are found on this Mac; "set <id>" checks the key with the service and
   * keeps it; "remove <id>" forgets it. The key goes in an env var, never on the command line. `done` gets the error
   * text, "" when none. False only when one is still running.
   */
  @discardableResult
  func runKeys(_ args: [String], key: String? = nil, done: ((String) -> Void)? = nil) -> Bool {
    guard keysProc == nil else { return false }
    keysProc = runScript("keys.ts", args, timeout: 40, env: key.map { ["OPENUSAGE_KEY": $0] } ?? [:]) { raw, timedOut in
      self.keysProc = nil
      var error = timedOut ? "timed out" : ""
      if let r = try? JSONDecoder().decode(KeysResult.self, from: raw) {
        self.keys = Dictionary(uniqueKeysWithValues: r.keys.map { ($0.id, $0) })
        error = r.error ?? ""
      } else if error.isEmpty {
        error = "couldn't read the keys"
      }
      done?(error)
    }
    if keysProc == nil { done?("node not found") }
    return true
  }

  /** "check" asks how far behind the remote this copy is; "apply" fast-forwards it and rebuilds the app. */
  func runUpdate(_ action: String) {
    guard updateProc == nil else { return }
    update.busy = action
    updateProc = runScript("update.ts", [action], timeout: 180) { raw, _ in
      self.updateProc = nil
      self.update.busy = ""
      guard let r = try? JSONDecoder().decode(UpdateInfo.self, from: raw) else {
        self.update.error = "update check failed"
        return
      }
      self.update.version = r.version ?? ""
      self.update.commit = r.commit ?? ""
      self.update.error = r.error ?? ""
      if let b = r.behind { self.update.behind = b }
      self.update.checked = true
      if action == "apply", r.updated == true, r.error == nil { self.rebuildAndRelaunch() }
    }
    if updateProc == nil {
      update.busy = ""
      update.error = "node not found"
    }
  }

  /** New Swift code needs a new build: build.sh quits this app, rebuilds it in place, then it is opened again. */
  func rebuildAndRelaunch() {
    guard let root = resource("root") else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "sleep 1; \"$0/widget-mac/build.sh\" \"$1\" && open \"$1\"", root, Bundle.main.bundlePath]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
  }

  private func complete(_ raw: Data, timedOut: Bool) {
    proc = nil
    refreshing = false
    guard let fresh = try? JSONDecoder().decode([ProviderUsage].self, from: raw) else {
      lastError = timedOut ? "timed out" : "refresh failed"
      return
    }
    // A transient provider failure keeps the last good numbers, flagged as stale.
    let prev = Dictionary(data.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
    data = fresh.map { u in
      if let err = u.error, var old = prev[u.uid], !old.windows.isEmpty {
        old.error = err
        return old
      }
      return u
    }
    updatedAt = Date().timeIntervalSince1970 * 1000
    lastError = ""
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    if let json = try? JSONEncoder().encode(Cache(updatedAt: updatedAt, data: data)) {
      try? json.write(to: cacheURL)
    }
  }

  /**
   * In compact mode a provider with no account at all (never signed in, no key, nothing to show) gets no card;
   * the normal layout keeps it, with the hint on how to sign in.
   */
  var shown: [ProviderUsage] {
    let on = data.filter { !hiddenProviders.contains($0.id) }
    if layout == "normal" { return on }
    return on.filter { $0.account != nil || !$0.windows.isEmpty || !$0.extras.isEmpty || $0.error == nil }
  }

  var providerCount: Int { providerNames.filter { !hiddenProviders.contains($0.id) }.count }

  var trayText: String {
    let parts = data.filter { !hiddenProviders.contains($0.id) }.compactMap { u -> String? in
      guard let m = u.windows.map(\.usedPct).max() else { return nil }
      return "\(u.name) \(Int(m.rounded()))%"
    }
    return parts.isEmpty ? "OpenUsage" : "OpenUsage - " + parts.joined(separator: " | ")
  }
}

// ---- theme (follows macOS light/dark) ------------------------------------------

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

func themed(_ light: UInt32, _ dark: UInt32) -> Color {
  Color(
    nsColor: NSColor(name: nil) { ap in
      NSColor(hex: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    })
}

enum C {
  static let bg = themed(0xFBFAF8, 0x1C1A19)
  static let border = themed(0xE2DDD7, 0x34302D)
  static let divider = themed(0xECE8E3, 0x2C2926)
  static let text = themed(0x1F1C1A, 0xEBE7E2)
  static let muted = themed(0x857D76, 0x8D8680)
  static let warn = themed(0xC46D12, 0xE8953F)
  static let error = themed(0xC9362D, 0xE5584F)
  static let track = themed(0xE4DED7, 0x35302C)
  static let hover = themed(0xF1EDE8, 0x2A2725)
  static let card = themed(0xF3F0EB, 0x242120)
  static let cardBorder = themed(0xE8E3DD, 0x2E2A27)
  static let ok = themed(0x2E8B57, 0x5BBF86)
}

let accents: [String: Color] = [
  "claude": themed(0xD97757, 0xD97757), "codex": themed(0x0F8A6C, 0x3DBE9C), "copilot": themed(0x8250DF, 0xA371F7), "kilo": themed(0xA68A00, 0xF2D33C),
  "devin": themed(0x2563EB, 0x60A5FA), "openrouter": themed(0x4F46E5, 0x818CF8), "zai": themed(0x0E7490, 0x22D3EE),
]

func level(_ pct: Double) -> Color? { pct >= 80 ? C.error : pct >= 50 ? C.warn : nil }

// ---- formatting ------------------------------------------------------------------

func formatReset(_ ms: Double?) -> String {
  guard let ms = ms else { return "" }
  let d = Date(timeIntervalSince1970: ms / 1000)
  let time = DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
  if Calendar.current.isDateInToday(d) { return time }
  let f = DateFormatter()
  f.setLocalizedDateFormatFromTemplate("EEEddMMM")
  return f.string(from: d) + ", " + time
}

/** Shorter, for the compact rows: "14:00", "Wed 14:00" within the week, else "14 Oct". */
func formatResetShort(_ ms: Double?) -> String {
  guard let ms = ms else { return "" }
  let d = Date(timeIntervalSince1970: ms / 1000)
  let time = DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short)
  if Calendar.current.isDateInToday(d) { return time }
  let f = DateFormatter()
  if d.timeIntervalSinceNow < 6 * 86400 {
    f.setLocalizedDateFormatFromTemplate("EEE")
    return f.string(from: d) + " " + time
  }
  f.setLocalizedDateFormatFromTemplate("ddMMM")
  return f.string(from: d)
}

func formatAgo(_ ms: Double?) -> String {
  guard let ms = ms else { return "" }
  let m = Int(((Date().timeIntervalSince1970 * 1000 - ms) / 60000).rounded())
  if m < 1 { return "updated just now" }
  if m < 60 { return "updated \(m) min ago" }
  return "updated \(Int((Double(m) / 60).rounded())) h ago"
}

// ---- provider marks ----------------------------------------------------------------
// The providers' own marks (assets/providers/*.svg, one path each), filled with the provider's color;
// the glyphs in `icons` stand in for any without one.

/** Minimal SVG path parser: M L H V C S Q T Z, absolute and relative, implicit repeats (no arcs; the marks use none). */
func parseSVGPath(_ d: String) -> Path {
  var path = Path()
  let chars = Array(d)
  let n = chars.count
  var i = 0
  var cur = CGPoint.zero
  var start = CGPoint.zero
  var lastControl: CGPoint?
  var cmd: Character = " "
  var prevCubic = false
  var prevQuad = false

  func skip() {
    while i < n, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
  }
  func number() -> CGFloat? {
    skip()
    var t = ""
    if i < n, chars[i] == "+" || chars[i] == "-" {
      t.append(chars[i])
      i += 1
    }
    var dot = false
    while i < n {
      let c = chars[i]
      if c.isNumber {
        t.append(c)
      } else if c == "." && !dot {
        dot = true
        t.append(c)
      } else if c == "e" || c == "E" {
        t.append(c)
        if i + 1 < n, chars[i + 1] == "+" || chars[i + 1] == "-" {
          i += 1
          t.append(chars[i])
        }
      } else {
        break
      }
      i += 1
    }
    return Double(t).map { CGFloat($0) }
  }
  func point(_ rel: Bool) -> CGPoint? {
    guard let x = number(), let y = number() else { return nil }
    return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
  }
  func reflected() -> CGPoint {
    guard let c = lastControl else { return cur }
    return CGPoint(x: 2 * cur.x - c.x, y: 2 * cur.y - c.y)
  }

  while i < n {
    skip()
    if i >= n { break }
    if chars[i].isLetter {
      cmd = chars[i]
      i += 1
    }
    let rel = cmd.isLowercase
    var ok = true
    var cubic = false
    var quad = false
    switch cmd {
    case "M", "m":
      if let p = point(rel) {
        path.move(to: p)
        cur = p
        start = p
        cmd = rel ? "l" : "L"
      } else { ok = false }
    case "L", "l":
      if let p = point(rel) {
        path.addLine(to: p)
        cur = p
      } else { ok = false }
    case "H", "h":
      if let x = number() {
        cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
        path.addLine(to: cur)
      } else { ok = false }
    case "V", "v":
      if let y = number() {
        cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
        path.addLine(to: cur)
      } else { ok = false }
    case "C", "c":
      if let c1 = point(rel), let c2 = point(rel), let e = point(rel) {
        path.addCurve(to: e, control1: c1, control2: c2)
        cur = e
        lastControl = c2
        cubic = true
      } else { ok = false }
    case "S", "s":
      if let c2 = point(rel), let e = point(rel) {
        path.addCurve(to: e, control1: prevCubic ? reflected() : cur, control2: c2)
        cur = e
        lastControl = c2
        cubic = true
      } else { ok = false }
    case "Q", "q":
      if let c = point(rel), let e = point(rel) {
        path.addQuadCurve(to: e, control: c)
        cur = e
        lastControl = c
        quad = true
      } else { ok = false }
    case "T", "t":
      if let e = point(rel) {
        let c = prevQuad ? reflected() : cur
        path.addQuadCurve(to: e, control: c)
        cur = e
        lastControl = c
        quad = true
      } else { ok = false }
    case "Z", "z":
      path.closeSubpath()
      cur = start
      // A number right after Z has no command to belong to.
      cmd = " "
    default:
      ok = false
    }
    if !ok { break }
    prevCubic = cubic
    prevQuad = quad
  }
  return path
}

final class Marks {
  static var cache: [String: Path] = [:]
  static var missing = Set<String>()

  static func path(_ id: String) -> Path? {
    let name = id == "opencode-go" ? "opencode" : id
    if let p = cache[name] { return p }
    if missing.contains(name) { return nil }
    guard let root = resource("root"),
      let svg = try? String(contentsOfFile: root + "/assets/providers/\(name).svg", encoding: .utf8),
      let re = try? NSRegularExpression(pattern: #"\sd="([^"]+)""#)
    else {
      missing.insert(name)
      return nil
    }
    let ns = svg as NSString
    let ds = re.matches(in: svg, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    if ds.isEmpty {
      missing.insert(name)
      return nil
    }
    let p = parseSVGPath(ds.joined(separator: " "))
    cache[name] = p
    return p
  }
}

/** A mark fitted to its frame by its real bounds, so every provider looks the same size. */
struct MarkShape: Shape {
  let mark: Path

  func path(in rect: CGRect) -> Path {
    let b = mark.boundingRect
    guard b.width > 0, b.height > 0 else { return mark }
    let k = min(rect.width / b.width, rect.height / b.height)
    return mark
      .applying(CGAffineTransform(translationX: -b.midX, y: -b.midY))
      .applying(CGAffineTransform(scaleX: k, y: k))
      .applying(CGAffineTransform(translationX: rect.midX, y: rect.midY))
  }
}

struct Logo: View {
  let id: String
  let color: Color
  var size: CGFloat = 13

  var body: some View {
    if let mark = Marks.path(id) {
      MarkShape(mark: mark).fill(color).frame(width: size, height: size)
    } else {
      Text(icons[id] ?? "").font(.system(size: size * 0.9)).foregroundColor(color)
    }
  }
}

/** Mark + name, for card headers and settings rows. */
struct LogoTitle: View {
  let id: String
  let text: String
  var size: CGFloat = 13.5
  var weight: Font.Weight = .semibold

  var body: some View {
    HStack(spacing: 7) {
      Logo(id: id, color: accents[id] ?? C.text, size: size + 0.5)
      Text(text).font(.system(size: size, weight: weight))
    }
  }
}

// ---- motion ---------------------------------------------------------------------------

/** 0..1..0 breathing over `period` seconds. */
func breathe(_ date: Date, _ period: Double = 2.2) -> Double {
  0.5 - 0.5 * cos(2 * Double.pi * date.timeIntervalSinceReferenceDate / period)
}

/** A limit at 80% or more breathes a soft glow in its warning color. */
struct Glow: ViewModifier {
  let on: Bool
  let color: Color
  var radius: CGFloat = 6

  @ViewBuilder func body(content: Content) -> some View {
    if on {
      TimelineView(.animation) { tl in
        content.shadow(color: color.opacity(0.15 + 0.75 * breathe(tl.date)), radius: radius)
      }
    } else {
      content
    }
  }
}

/** First show: blocks fade in and rise one after the other. */
struct Intro: ViewModifier {
  let index: Int
  var step: Double = 0.07
  @StateObject private var shown = LocalState(false)

  func body(content: Content) -> some View {
    content
      .opacity(shown.value ? 1 : 0)
      .offset(y: shown.value ? 0 : 10)
      .onAppear {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.68).delay(Double(index) * step)) { shown.value = true }
      }
  }
}

/** Cards: the border lights up and the card lifts a little under the pointer. */
struct Lift: ViewModifier {
  let radius: CGFloat
  @StateObject private var hover = LocalState(false)

  func body(content: Content) -> some View {
    content
      .overlay(RoundedRectangle(cornerRadius: radius).stroke(C.border, lineWidth: 1).opacity(hover.value ? 1 : 0))
      .offset(y: hover.value ? -2 : 0)
      .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hover.value)
      .onHover { hover.value = $0 }
  }
}

/** While a refresh runs, a soft light sweeps across the widget. */
struct Shimmer: View {
  let radius: CGFloat
  var diagonal = true

  var body: some View {
    TimelineView(.animation) { tl in
      let t = tl.date.timeIntervalSinceReferenceDate / 1.3
      let k = 0.5 - 0.5 * cos(Double.pi * (t - floor(t)))
      let c = -0.2 + 1.4 * k
      LinearGradient(
        stops: [
          .init(color: C.text.opacity(0), location: 0), .init(color: C.text.opacity(0.11), location: 0.5),
          .init(color: C.text.opacity(0), location: 1),
        ],
        startPoint: UnitPoint(x: c - 0.25, y: diagonal ? -0.2 : 0.5),
        endPoint: UnitPoint(x: c + 0.25, y: diagonal ? 1.2 : 0.5))
    }
    .clipShape(RoundedRectangle(cornerRadius: radius))
    .allowsHitTesting(false)
  }
}

/** A rounded track whose fill slides in from the left, in a gradient of its color. */
struct Meter: View {
  let used: Double
  var display = "used"
  let color: Color
  var width: CGFloat? = nil
  var height: CGFloat = 4
  var delay: Double = 0
  @StateObject private var appeared = LocalState(false)

  var body: some View {
    // A used-up limit stays full (in red), whether numbers show used or left.
    let value = used >= 100 ? 100 : max(0, min(100, display == "used" ? used : 100 - used))
    let p = appeared.value ? CGFloat(value / 100) : 0
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(C.track)
        if p > 0 {
          Capsule()
            .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
            .frame(width: max(height, g.size.width * p))
            .modifier(Glow(on: used >= 80, color: color, radius: 4))
        }
      }
    }
    .frame(width: width, height: height)
    .animation(.easeOut(duration: 0.55), value: p)
    .onAppear { withAnimation(.easeOut(duration: 0.75).delay(delay)) { appeared.value = true } }
  }
}

/** A few letters, so meters line up: "Credits" -> "cr", "Daily" -> "day". */
func shortSlot(_ w: UsageWindow) -> String {
  let n = slotName(w)
  if n.hasPrefix("Credit") { return "cr" }
  if n.hasPrefix("Daily") { return "day" }
  return n.count > 3 ? String(n.prefix(3)).lowercased() : n
}

/** Used up and still waiting on its reset (a reset already past means the numbers are behind, not the limit). */
func isOut(_ w: UsageWindow) -> Bool {
  w.usedPct >= 100 && (w.resetsAt ?? 0) > Date().timeIntervalSince1970 * 1000
}

/** 5h ▬▬▬▬▭▭ 72% */
struct MeterLine: View {
  let w: UsageWindow
  let display: String
  let accent: Color
  let length: CGFloat
  let index: Int

  var body: some View {
    let lv = level(w.usedPct)
    HStack(spacing: 0) {
      Text(shortSlot(w)).font(.system(size: 10)).foregroundColor(C.muted).frame(minWidth: 16, alignment: .leading)
      if isOut(w) {
        // Used up: no bar, just when it comes back, in the room the bar and the number take.
        Text("\u{21BB} \(formatResetShort(w.resetsAt))").font(.system(size: 11, weight: .semibold)).foregroundColor(C.error)
          .frame(minWidth: length + 32, alignment: .leading)
          .padding(.leading, 3)
      } else {
        Meter(used: w.usedPct, display: display, color: lv ?? accent, width: length, height: 5, delay: 0.12 + 0.07 * Double(index))
          .padding(.leading, 3)
          .padding(.trailing, 5)
        Text("\(Int(shown(w, display).rounded()))%").font(.system(size: 11, weight: .semibold)).foregroundColor(lv ?? C.text)
          .frame(minWidth: 27, alignment: .leading)
      }
    }
  }
}

func baseName(_ u: ProviderUsage) -> String {
  u.name.replacingOccurrences(of: " \\(.*\\)$", with: "", options: .regularExpression)
}

// ---- views -----------------------------------------------------------------------

/// View-local state without `@State`: in recent SDKs `@State` is a macro whose plugin only ships with
/// full Xcode, so it does not compile with the Command Line Tools alone.
final class LocalState<Value>: ObservableObject {
  @Published var value: Value
  init(_ value: Value) { self.value = value }
}

struct HeaderButton: View {
  let title: String
  let help: String
  /** The refresh arrow turns while a refresh runs. */
  var spinning = false
  let action: () -> Void
  @StateObject private var hover = LocalState(false)

  var body: some View {
    Button(action: action) {
      glyph
        .font(.system(size: 12))
        .foregroundColor(hover.value ? C.text : C.muted)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover.value ? C.hover : Color.clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { hover.value = $0 }
  }

  @ViewBuilder var glyph: some View {
    if spinning {
      TimelineView(.animation) { tl in
        let turns = tl.date.timeIntervalSinceReferenceDate / 0.9
        Text(title).rotationEffect(.degrees((turns - floor(turns)) * 360))
      }
    } else {
      Text(title)
    }
  }
}

struct Card: View {
  let u: ProviderUsage
  let display: String
  var index = 0

  var body: some View {
    let hasData = !u.windows.isEmpty || !u.extras.isEmpty
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        LogoTitle(id: u.id, text: u.name)
        Spacer()
        if let plan = u.plan {
          Text(plan.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(C.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(C.track))
        }
      }
      if let account = u.account {
        Text(account).font(.system(size: 11.5)).foregroundColor(C.muted).lineLimit(1).truncationMode(.tail)
          .help(account).padding(.top, 1)
      }
      if let err = u.error {
        Text(hasData ? "stale - \(err)" : err)
          .font(.system(size: 12))
          .foregroundColor(hasData ? C.warn : C.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 6)
      }
      ForEach(Array(u.windows.enumerated()), id: \.offset) { i, w in
        let pct = display == "used" ? w.usedPct : 100 - w.usedPct
        let lv = level(w.usedPct)
        HStack {
          let reset = formatReset(w.resetsAt)
          (Text(w.label) + Text(reset.isEmpty ? "" : "  \(reset)").font(.system(size: 12)).foregroundColor(C.muted))
            .lineLimit(1).truncationMode(.tail)
          Spacer()
          Text("\(Int(pct.rounded()))%").font(.system(size: 13, weight: .semibold)).foregroundColor(lv ?? C.text)
        }
        .padding(.top, i == 0 ? 9 : 8)
        Meter(used: w.usedPct, display: display, color: lv ?? C.muted, delay: 0.12 + 0.07 * Double(index)).padding(.top, 5)
      }
      ForEach(Array(u.extras.enumerated()), id: \.offset) { i, x in
        HStack {
          Text(x.label).foregroundColor(C.muted)
          Spacer()
          Text(x.value)
        }
        .font(.system(size: 12.5))
        .padding(.top, u.windows.isEmpty && i == 0 ? 9 : 8)
      }
    }
    .padding(EdgeInsets(top: 9, leading: 11, bottom: 10, trailing: 11))
    .background(RoundedRectangle(cornerRadius: 8).fill(C.card))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.cardBorder, lineWidth: 1))
    .modifier(Lift(radius: 8))
    .modifier(Intro(index: index))
  }
}

// ---- compact ---------------------------------------------------------------------
// One card per provider, one line per account with a ring pair: outer arc = weekly (or the billing cycle), inner = 5 hours.

struct Slots {
  var short: UsageWindow?
  var long: UsageWindow?
}

func slots(_ u: ProviderUsage) -> Slots {
  let short = u.windows.first { $0.label.contains("Hour") }
  var long = u.windows.first { $0.label.contains("Week") || $0.label.contains("7-Day Limit") }
  if long == nil {
    long = u.windows.first {
      $0.label != short?.label && !$0.label.contains("Opus") && !$0.label.contains("Sonnet")
    }
  }
  return Slots(short: short, long: long)
}

func slotName(_ w: UsageWindow?) -> String {
  guard let l = w?.label else { return "" }
  if l.contains("Hour") { return "5h" }
  if l.contains("Week") || l.contains("7-Day") { return "wk" }
  if l.contains("Month") || l.contains("Billing") { return "mo" }
  return l
}

func shown(_ w: UsageWindow, _ display: String) -> Double { display == "used" ? w.usedPct : 100 - w.usedPct }

/** "paulo" for paulo@example.com; without a known account, the profile folder (".claude-2") or nothing. */
func shortAccount(_ u: ProviderUsage) -> String {
  if let a = u.account, let local = a.split(separator: "@").first { return String(local) }
  if let r = u.name.range(of: #"\((.+)\)$"#, options: .regularExpression) {
    return String(u.name[r].dropFirst().dropLast())
  }
  return ""
}

/** Everything the ring leaves out: every limit with its reset, the plan and any error. */
func tipText(_ u: ProviderUsage, _ display: String) -> String {
  var lines = [(u.account ?? u.name) + (u.plan.map { "  -  " + $0.uppercased() } ?? "")]
  for w in u.windows {
    let reset = formatReset(w.resetsAt)
    lines.append(
      "\(w.label)   \(Int(shown(w, display).rounded()))% \(display == "used" ? "used" : "left")"
        + (reset.isEmpty ? "" : "  -  resets \(reset)"))
  }
  for x in u.extras { lines.append("\(x.label)   \(x.value)") }
  if let e = u.error { lines.append(e) }
  return lines.joined(separator: "\n")
}

/** Outer arc = weekly (or the billing cycle), inner arc = 5 hours. The numbers sit beside it, not inside. */
struct Ring: View {
  let u: ProviderUsage
  let display: String
  var size: CGFloat = 42
  var t: CGFloat = 4
  /** The strip puts the provider's mark in the middle, in this color. */
  var mark: Color? = nil
  // Arcs grow from zero when the ring first appears, then follow new values.
  @StateObject private var appeared = LocalState(false)

  var body: some View {
    let s = slots(u)
    let inner = size - 2 * (t + 3)
    let hot = [s.short, s.long].contains { ($0?.usedPct ?? 0) >= 80 }
    let both = s.short != nil && s.long != nil
    ZStack {
      Circle().stroke(C.track, lineWidth: t).frame(width: size - t, height: size - t)
      if both { Circle().stroke(C.track, lineWidth: t).frame(width: inner - t, height: inner - t) }
      if let long = s.long { arc(long, diameter: size - t, width: t, color: level(long.usedPct) ?? C.muted) }
      if let short = s.short {
        arc(short, diameter: (both ? inner : size) - t, width: t, color: level(short.usedPct) ?? C.text)
      }
      if s.short == nil && s.long == nil {
        Text("!").font(.system(size: 13, weight: .semibold)).foregroundColor(C.warn)
      } else if let mark = mark {
        Logo(id: u.id, color: mark, size: (size * 0.4).rounded())
      }
    }
    .frame(width: size, height: size)
    .modifier(Glow(on: hot, color: C.error, radius: 7))
    .onAppear { withAnimation(.easeOut(duration: 0.55)) { appeared.value = true } }
  }

  func arc(_ w: UsageWindow, diameter: CGFloat, width: CGFloat, color: Color) -> some View {
    // A used-up limit is always a full ring (in red), whether numbers show used or left.
    let pct = w.usedPct >= 100 ? 100 : shown(w, display)
    let p = appeared.value ? CGFloat(max(0, min(100, pct)) / 100) : 0
    return Circle()
      .trim(from: 0, to: p)
      .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
      .rotationEffect(.degrees(-90))
      .frame(width: diameter, height: diameter)
      // Under 1% a round-capped arc is just a dot, which reads as noise.
      .opacity(p < 0.01 ? 0 : 1)
      .animation(.easeOut(duration: 0.55), value: p)
  }
}

/** One line per account: ring, name with plan and next reset, then the 5h / weekly numbers on the right. */
struct AccountRow: View {
  let u: ProviderUsage
  let display: String
  @StateObject private var hover = LocalState(false)

  var body: some View {
    let s = slots(u)
    let ws = [s.short, s.long].compactMap { $0 }
    let plan = u.plan?.uppercased() ?? ""
    let short = shortAccount(u)
    // Without a known account (an API key, say) there is no name: the plan, or just the next line, leads.
    let title = !short.isEmpty ? short : plan
    let sub: (String, Color) = {
      if let e = u.error { return ws.isEmpty ? (e, C.muted) : ("stale", C.warn) }
      var parts: [String] = []
      if !short.isEmpty && !plan.isEmpty { parts.append(plan) }
      if let r = (s.short ?? s.long)?.resetsAt { parts.append("\u{21BB} \(formatResetShort(r))") }
      return (parts.joined(separator: "  \u{00B7}  "), C.muted)
    }()
    HStack(spacing: 0) {
      Ring(u: u, display: display)
      VStack(alignment: .leading, spacing: 1) {
        if !title.isEmpty { Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail) }
        if !sub.0.isEmpty {
          Text(sub.0).font(.system(size: title.isEmpty ? 12 : 11.5)).foregroundColor(sub.1)
            .lineLimit(title.isEmpty ? 2 : 1).truncationMode(.tail)
        }
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      Spacer(minLength: 0)
      // Numbers in a column of their own, so the percentages line up.
      VStack(alignment: .trailing, spacing: 2) {
        ForEach(Array(ws.enumerated()), id: \.offset) { _, w in
          HStack(spacing: 8) {
            Text(slotName(w)).font(.system(size: 11.5)).foregroundColor(C.muted)
            Text("\(Int(shown(w, display).rounded()))%").font(.system(size: 13, weight: .semibold))
              .foregroundColor(level(w.usedPct) ?? C.text)
              .frame(minWidth: 34, alignment: .trailing)
          }
        }
      }
    }
    .padding(EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 8))
    .background(RoundedRectangle(cornerRadius: 8).fill(hover.value ? C.hover : Color.clear))
    .onHover { hover.value = $0 }
    .help(tipText(u, display))
    .padding(.horizontal, -6)
  }
}

/** Compact with bars: one short line per account, its name and a meter per limit. */
struct AccountMeterRow: View {
  let u: ProviderUsage
  let display: String
  let accent: Color
  let index: Int
  @StateObject private var hover = LocalState(false)

  var title: String {
    let short = shortAccount(u)
    if !short.isEmpty { return short }
    // No account to name (an API key): the balance says more than the plan already in the header.
    if let bal = u.extras.first(where: { $0.label.contains("Balance") }), !u.windows.isEmpty { return "\(bal.value) balance" }
    return baseName(u)
  }

  var body: some View {
    let s = slots(u)
    let ws = [s.short, s.long].compactMap { $0 }
    HStack(spacing: 8) {
      Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
      HStack(spacing: 6) {
        if !ws.isEmpty {
          ForEach(Array(ws.enumerated()), id: \.offset) { _, w in
            MeterLine(w: w, display: display, accent: accent, length: ws.count == 1 ? 112 : 36, index: index)
          }
        } else if let x = u.extras.first {
          Text(x.label.lowercased()).font(.system(size: 11)).foregroundColor(C.muted)
          Text(x.value).font(.system(size: 12, weight: .semibold))
        } else {
          Text(u.error ?? "no data").font(.system(size: 11)).foregroundColor(C.muted).lineLimit(1)
        }
      }
      .opacity(u.error != nil && !ws.isEmpty ? 0.55 : 1)
    }
    .padding(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
    .background(RoundedRectangle(cornerRadius: 6).fill(hover.value ? C.hover : Color.clear))
    .animation(.easeOut(duration: 0.16), value: hover.value)
    .onHover { hover.value = $0 }
    .help(tipText(u, display))
    .padding(.horizontal, -6)
  }
}

struct ProviderGroup: Identifiable {
  let id: String
  let accounts: [ProviderUsage]
}

/** Accounts grouped by provider, keeping the order providers arrive in. */
func groups(_ data: [ProviderUsage]) -> [ProviderGroup] {
  var order: [String] = []
  var byId: [String: [ProviderUsage]] = [:]
  for u in data {
    if byId[u.id] == nil { order.append(u.id) }
    byId[u.id, default: []].append(u)
  }
  return order.map { ProviderGroup(id: $0, accounts: byId[$0] ?? []) }
}

struct CompactCard: View {
  let g: ProviderGroup
  let display: String
  var gauge = "ring"
  var index = 0

  var body: some View {
    let first = g.accounts[0]
    let name = baseName(first)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        LogoTitle(id: g.id, text: name)
        Spacer()
        Text(g.accounts.count > 1 ? "\(g.accounts.count) accounts" : (first.plan?.uppercased() ?? ""))
          .font(.system(size: 10.5, weight: .semibold)).foregroundColor(C.muted)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(g.accounts, id: \.uid) { u in
          if gauge == "bar" {
            AccountMeterRow(u: u, display: display, accent: accents[g.id] ?? C.text, index: index)
          } else {
            AccountRow(u: u, display: display)
          }
        }
      }
      .padding(.top, gauge == "bar" ? 4 : 6)
    }
    .padding(EdgeInsets(top: gauge == "bar" ? 8 : 10, leading: 12, bottom: 6, trailing: 12))
    .background(RoundedRectangle(cornerRadius: 10).fill(C.card))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.cardBorder, lineWidth: 1))
    .modifier(Lift(radius: 10))
    .modifier(Intro(index: index))
  }
}

// ---- strip ---------------------------------------------------------------------------

/** The used-up limit that frees up last (when you can work again), or nil while every limit has room. */
func blocked(_ s: Slots) -> UsageWindow? {
  [s.short, s.long].compactMap { $0 }.filter(isOut).max { $0.resetsAt! < $1.resetsAt! }
}

/** One account in the strip: a ring pair around the mark (or the mark and a meter per limit) and its numbers. */
struct StripChip: View {
  let u: ProviderUsage
  let display: String
  let gauge: String
  let index: Int
  @StateObject private var hover = LocalState(false)

  var body: some View {
    let s = slots(u)
    let ws = [s.short, s.long].compactMap { $0 }
    let accent = accents[u.id] ?? C.text
    HStack(spacing: 7) {
      if gauge == "bar" {
        Logo(id: u.id, color: accent, size: 14)
          .frame(width: 26, height: 26)
          .background(Circle().fill(C.card))
        meters(ws, accent)
      } else {
        Ring(u: u, display: display, size: 32, t: 3, mark: accent)
        numbers(s)
      }
    }
    .padding(EdgeInsets(top: 3, leading: 3, bottom: 3, trailing: gauge == "bar" ? 6 : 10))
    .background(RoundedRectangle(cornerRadius: 17).fill(hover.value ? C.hover : Color.clear))
    .scaleEffect(hover.value ? 1.06 : 1)
    .animation(.spring(response: 0.25, dampingFraction: 0.55), value: hover.value)
    .onHover { hover.value = $0 }
    .help(tipText(u, display))
    // Numbers kept from a failed refresh fade back a little.
    .opacity(u.error != nil && !ws.isEmpty ? 0.55 : 1)
    .modifier(Intro(index: index))
  }

  func who(_ ws: [UsageWindow]) -> String {
    let a = shortAccount(u)
    if !a.isEmpty { return a }
    if let x = u.extras.first { return "\(x.value) \(x.label.lowercased())" }
    return ""
  }

  @ViewBuilder func meters(_ ws: [UsageWindow], _ accent: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if !ws.isEmpty {
        ForEach(Array(ws.enumerated()), id: \.offset) { _, w in
          MeterLine(w: w, display: display, accent: accent, length: 46, index: index)
        }
        if ws.count == 1 && !who(ws).isEmpty {
          Text(who(ws)).font(.system(size: 10)).foregroundColor(C.muted)
        }
      } else if let x = u.extras.first {
        Text(x.value).font(.system(size: 12.5, weight: .semibold))
        Text(x.label.lowercased()).font(.system(size: 10)).foregroundColor(C.muted)
      } else {
        Text(baseName(u)).font(.system(size: 12, weight: .semibold))
        Text(u.error != nil ? "error" : "no data").font(.system(size: 10)).foregroundColor(u.error != nil ? C.warn : C.muted)
      }
    }
  }

  @ViewBuilder func numbers(_ s: Slots) -> some View {
    let main = s.short ?? s.long
    let other = s.short != nil ? s.long : nil
    VStack(alignment: .leading, spacing: 0) {
      if let main = main {
        (Text("\(Int(shown(main, display).rounded()))%").font(.system(size: 13, weight: .semibold))
          .foregroundColor(level(main.usedPct) ?? C.text)
          + Text(" \(slotName(main))").font(.system(size: 10)).foregroundColor(C.muted))
        // A used-up limit: the second line tells when it comes back instead.
        if let b = blocked(s) {
          // Named when it isn't the limit on the line above.
          Text("\(b.label == main.label ? "" : slotName(b) + " ")\u{21BB} \(formatResetShort(b.resetsAt))").font(.system(size: 10)).foregroundColor(C.error)
        } else if let other = other {
          Text("\(slotName(other)) \(Int(shown(other, display).rounded()))%").font(.system(size: 10))
            .foregroundColor(level(other.usedPct) ?? C.muted)
        } else if !shortAccount(u).isEmpty {
          Text(shortAccount(u)).font(.system(size: 10)).foregroundColor(C.muted)
        }
      } else if let x = u.extras.first {
        Text(x.value).font(.system(size: 13, weight: .semibold))
        Text(x.label.lowercased()).font(.system(size: 10)).foregroundColor(C.muted)
      } else {
        Text(baseName(u)).font(.system(size: 12, weight: .semibold))
        Text("no data").font(.system(size: 10)).foregroundColor(C.muted)
      }
    }
  }
}

/** The strip: a slim pill, a chip per account; its buttons stay faint until the pointer comes over it. */
struct StripView: View {
  @ObservedObject var m: Model
  let settings: () -> Void
  @StateObject private var hover = LocalState(false)

  var body: some View {
    let shown = m.shown
    HStack(spacing: 2) {
      Text("\u{25F7}").font(.system(size: 14)).foregroundColor(C.muted).frame(width: 26, height: 38)
        .help(m.lastError.isEmpty ? "OpenUsage - \(formatAgo(m.updatedAt))" : "OpenUsage - \(m.lastError)")
      ForEach(Array(shown.enumerated()), id: \.element.uid) { i, u in
        // A hairline between providers; accounts of the same provider sit together.
        if i > 0 && shown[i - 1].id != u.id {
          Rectangle().fill(C.divider).frame(width: 1, height: 20).padding(.horizontal, 3)
        }
        StripChip(u: u, display: m.display, gauge: m.gauge, index: i)
      }
      if shown.isEmpty {
        Text(m.refreshing ? "Loading..." : "No data").font(.system(size: 12)).foregroundColor(C.muted)
          .padding(.leading, 4).padding(.trailing, 8)
      }
      HStack(spacing: 0) {
        HeaderButton(title: "\u{27F3}", help: "Refresh", spinning: m.refreshing) { m.refresh() }
        HeaderButton(title: "\u{2699}", help: "Settings", action: settings)
          .overlay(alignment: .topTrailing) {
            if m.update.behind > 0 { Circle().fill(C.warn).frame(width: 6, height: 6).offset(x: -2, y: 1) }
          }
      }
      .padding(.leading, 2)
      .opacity(hover.value ? 1 : 0.35)
      .animation(.easeOut(duration: 0.25), value: hover.value)
    }
    .font(.system(size: 13))
    .foregroundColor(C.text)
    .padding(EdgeInsets(top: 4, leading: 5, bottom: 4, trailing: 5))
    .background(DragArea())
    .background(RoundedRectangle(cornerRadius: 23).fill(C.bg))
    .overlay(RoundedRectangle(cornerRadius: 23).stroke(C.border, lineWidth: 1))
    .overlay(Group { if m.refreshing { Shimmer(radius: 23, diagonal: false).transition(.opacity) } })
    .animation(.easeOut(duration: 0.3), value: m.refreshing)
    .onHover { hover.value = $0 }
    .fixedSize()
  }
}

// ---- settings --------------------------------------------------------------------

struct SegOption {
  let value: String
  let label: String
}

/** Pill-shaped choice, like the Windows settings: the picked option is filled. */
struct Segmented: View {
  let options: [SegOption]
  let value: String
  let pick: (String) -> Void
  @Namespace private var ns

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { o in
        let on = o.value == value
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { pick(o.value) }
        } label: {
          Text(o.label)
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .foregroundColor(on ? C.bg : C.muted)
            .frame(minWidth: 62)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
              Group {
                if on { RoundedRectangle(cornerRadius: 6).fill(C.text).matchedGeometryEffect(id: "pick", in: ns) }
              })
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: 8).fill(C.card))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.cardBorder, lineWidth: 1))
  }
}

struct DialogButton: View {
  let title: String
  var primary = false
  var enabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 13, weight: primary ? .semibold : .regular))
        .foregroundColor(primary ? C.bg : C.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(primary ? C.text : C.card))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(primary ? C.text : C.cardBorder, lineWidth: 1))
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
  }
}

struct SettingsView: View {
  @ObservedObject var m: Model
  let close: () -> Void
  let askKey: (String) -> Void
  // Opening: the panel pops in and its rows arrive one after the other.
  @StateObject private var appeared = LocalState(false)

  var body: some View {
    let u = m.update
    let status: (String, Color) = {
      if u.busy == "apply" { return ("Updating...", C.muted) }
      if u.busy == "check" { return ("Checking for updates...", C.muted) }
      if !u.error.isEmpty { return ("Can't update: \(u.error)", C.error) }
      if u.behind > 0 { return ("Update available: \(u.behind) new change\(u.behind > 1 ? "s" : "")", C.warn) }
      if u.checked { return ("Up to date", C.ok) }
      return ("Not checked yet", C.muted)
    }()
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        (Text("\u{2699}").foregroundColor(C.muted) + Text("  Settings")).font(.system(size: 14.5, weight: .semibold))
        Spacer()
        HeaderButton(title: "\u{2715}", help: "Close", action: close)
      }
      .padding(.bottom, 12)
      .background(DragArea())
      caption("DISPLAY").modifier(Intro(index: 1, step: 0.03))
      option("Numbers", "Default for every limit") {
        Segmented(
          options: [SegOption(value: "used", label: "Used"), SegOption(value: "remaining", label: "Left")],
          value: m.display, pick: { m.setDisplay($0) })
      }
      .modifier(Intro(index: 2, step: 0.03))
      option("Layout", layoutNote) {
        Segmented(
          options: [
            SegOption(value: "normal", label: "Normal"), SegOption(value: "compact", label: "Compact"),
            SegOption(value: "bar", label: "Strip"),
          ],
          value: m.layout, pick: { m.setLayout($0) })
      }
      .padding(.top, 8)
      .modifier(Intro(index: 3, step: 0.03))
      option("Gauges", gaugeNote) {
        Segmented(
          options: [SegOption(value: "ring", label: "Rings"), SegOption(value: "bar", label: "Bars")],
          value: m.gauge, pick: { m.setGauge($0) })
      }
      .padding(.top, 8)
      .modifier(Intro(index: 4, step: 0.03))
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 16).padding(.bottom, 14)
      caption("PROVIDERS").modifier(Intro(index: 5, step: 0.03))
      LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible())], alignment: .leading, spacing: 8) {
        ForEach(providerNames, id: \.id) { p in
          let on = !m.hiddenProviders.contains(p.id)
          HStack {
            LogoTitle(id: p.id, text: p.name, size: 13, weight: .regular)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { on }, set: { v in withAnimation(.easeOut(duration: 0.2)) { m.setProvider(p.id, on: v) } }))
              .toggleStyle(.switch).controlSize(.mini).labelsHidden()
              // The last one left on can't be switched off, so the widget is never empty.
              .disabled(on && m.providerCount <= 1)
              .help("Show \(p.name)")
          }
        }
      }
      .modifier(Intro(index: 6, step: 0.03))
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 14).padding(.bottom, 14)
      caption("API KEYS").modifier(Intro(index: 7, step: 0.03))
      Text("Found by itself when OpenCode, Kilo, Crush or Claude Code already use one; otherwise add it here.")
        .font(.system(size: 11.5)).foregroundColor(C.muted).fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 10)
        .modifier(Intro(index: 8, step: 0.03))
      ForEach(Array(keyedProviders.enumerated()), id: \.element) { i, pid in
        let k = m.keys[pid]
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            LogoTitle(id: pid, text: k?.name ?? pid, size: 13, weight: .regular)
            Text(keyStatus(k)).font(.system(size: 11)).foregroundColor(C.muted)
          }
          Spacer()
          if k?.saved == true {
            DialogButton(title: "Remove") { m.runKeys(["remove", pid]) { _ in m.refresh() } }
          }
          DialogButton(title: k?.source != nil ? "Change" : "Add key", enabled: k != nil) { askKey(pid) }
        }
        .padding(.bottom, 10)
        .modifier(Intro(index: 9 + i, step: 0.03))
      }
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 4).padding(.bottom, 14)
      caption("ABOUT").modifier(Intro(index: 12, step: 0.03))
      HStack(spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
        VStack(alignment: .leading, spacing: 1) {
          Text("OpenUsage").font(.system(size: 13.5, weight: .semibold))
          Text(u.version.isEmpty ? "..." : "v\(u.version)" + (u.commit.isEmpty ? "" : " \u{00B7} \(u.commit)"))
            .font(.system(size: 11.5, design: .monospaced)).foregroundColor(C.muted)
        }
      }
      HStack(spacing: 9) {
        Circle().fill(status.1).frame(width: 8, height: 8)
        Text(status.0).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(RoundedRectangle(cornerRadius: 8).fill(C.card))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(C.cardBorder, lineWidth: 1))
      .padding(.top, 12)
      HStack(spacing: 8) {
        Spacer()
        DialogButton(title: "Check for updates", enabled: u.busy.isEmpty) { m.runUpdate("check") }
        if u.behind > 0 && u.error.isEmpty {
          DialogButton(title: "Update now", primary: true, enabled: u.busy.isEmpty) { m.runUpdate("apply") }
        }
      }
      .padding(.top, 14)
    }
    .font(.system(size: 13))
    .foregroundColor(C.text)
    .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
    .frame(width: 356)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 12).fill(C.bg))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
    .scaleEffect(appeared.value ? 1 : 0.94, anchor: .top)
    .opacity(appeared.value ? 1 : 0)
    .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { appeared.value = true } }
  }

  var layoutNote: String {
    m.layout == "bar" ? "One slim strip" : m.layout == "compact" ? "A line per account" : "A card per account"
  }

  var gaugeNote: String {
    m.layout == "normal" ? "For Compact and Strip" : m.gauge == "bar" ? "Slim meters" : "Rings around the numbers"
  }

  func caption(_ s: String) -> some View {
    Text(s).font(.system(size: 10.5, weight: .semibold)).foregroundColor(C.muted).padding(.bottom, 8)
  }

  func option<V: View>(_ title: String, _ note: String, @ViewBuilder control: () -> V) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(note).font(.system(size: 11)).foregroundColor(C.muted)
      }
      Spacer()
      control()
    }
  }
}

struct WidgetView: View {
  @ObservedObject var m: Model
  let settings: () -> Void
  let add: () -> Void
  let hide: () -> Void
  // Re-renders the "updated N min ago" label.
  @StateObject private var now = LocalState(Date())
  private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

  var body: some View {
    if m.layout == "bar" {
      StripView(m: m, settings: settings)
    } else {
      panel
    }
  }

  var panel: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        (Text("\u{25F7}").foregroundColor(C.muted) + Text(" OpenUsage")).font(.system(size: 13, weight: .semibold))
        Spacer()
        HeaderButton(title: "\u{2699}", help: "Settings", action: settings)
          .overlay(alignment: .topTrailing) {
            // A new version is waiting.
            if m.update.behind > 0 { Circle().fill(C.warn).frame(width: 6, height: 6).offset(x: -2, y: 1) }
          }
        HeaderButton(title: "+", help: "Add account", action: add)
        HeaderButton(title: m.display == "used" ? "Used" : "Left", help: "Used / left") { m.toggleDisplay() }
        HeaderButton(title: "\u{27F3}", help: "Refresh", spinning: m.refreshing) { m.refresh() }
        HeaderButton(title: "\u{2715}", help: "Hide (menu bar icon brings it back)", action: hide)
      }
      .padding(.bottom, 8)
      .background(DragArea())
      Rectangle().fill(C.divider).frame(height: 1).padding(.bottom, 8)
      if m.shown.isEmpty {
        Text(m.refreshing ? "Loading..." : m.providerCount == 0 ? "No AI tool found on this Mac. Turn one on in settings (\u{2699})." : "No data")
          .foregroundColor(C.muted).fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 8) {
        if m.layout == "compact" {
          ForEach(Array(groups(m.shown).enumerated()), id: \.element.id) { i, g in
            CompactCard(g: g, display: m.display, gauge: m.gauge, index: i)
          }
        } else {
          ForEach(Array(m.shown.enumerated()), id: \.element.uid) { i, u in Card(u: u, display: m.display, index: i) }
        }
      }
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 10).padding(.bottom, 6)
      HStack {
        Text(m.refreshing ? "refreshing..." : formatAgo(m.updatedAt)).foregroundColor(C.muted)
        Spacer()
        Text(m.lastError).foregroundColor(C.error)
      }
      .font(.system(size: 11.5))
      .id(now.value)
    }
    .font(.system(size: 13))
    .foregroundColor(C.text)
    .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    .frame(width: 304)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 12).fill(C.bg))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(C.border, lineWidth: 1))
    .overlay(Group { if m.refreshing { Shimmer(radius: 12).transition(.opacity) } })
    .animation(.easeOut(duration: 0.3), value: m.refreshing)
    .onReceive(clock) { now.value = $0 }
  }
}

// ---- window ----------------------------------------------------------------------

/** The header drags the window, like the Windows widget. */
struct DragArea: NSViewRepresentable {
  final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

/** Borderless panels refuse key status by default, which would leave the buttons dead. */
final class Panel: NSPanel {
  override var canBecomeKey: Bool { true }
}

final class HostingView<V: View>: NSHostingView<V> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// ---- start at login --------------------------------------------------------------

let agentURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/LaunchAgents/\(bundleId).plist")

func setStartAtLogin(_ on: Bool) {
  if on {
    let plist: [String: Any] = [
      "Label": bundleId,
      "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
      "RunAtLoad": true,
    ]
    try? FileManager.default.createDirectory(
      at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    (plist as NSDictionary).write(to: agentURL, atomically: true)
  } else {
    try? FileManager.default.removeItem(at: agentURL)
  }
}

// ---- accounts ----------------------------------------------------------------------
// Each extra account lives in its own config folder in home (".claude-2", ".codex-work"...), which the
// providers find on their own. Adding one asks for a command name (e.g. "claude2") and opens Terminal on
// scripts/add-account.ts, which creates the folder and a claude2 command for it, then signs in.

struct AccountKind {
  let id: String
  let name: String
  let prefix: String
  let command: String
}

let accountKinds = [
  AccountKind(id: "claude", name: "Claude", prefix: ".claude", command: "claude"),
  AccountKind(id: "codex", name: "Codex", prefix: ".codex", command: "codex"),
]

let home = FileManager.default.homeDirectoryForCurrentUser.path

/** "claude2" -> ~/.claude-2, "claude-work" -> ~/.claude-work, "work" -> ~/.claude-work. */
func accountDir(_ k: AccountKind, _ name: String) -> String? {
  var suffix = Substring(name)
  if name.lowercased().hasPrefix(k.command) { suffix = suffix.dropFirst(k.command.count) }
  suffix = suffix.drop(while: { $0 == "-" || $0 == "_" })
  return suffix.isEmpty ? nil : "\(home)/\(k.prefix)-\(suffix)"
}

/** Apps started from Finder get a bare PATH, so also look where installers usually put CLIs. */
func commandExists(_ name: String) -> Bool {
  let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
  let dirs = path + ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
  return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
}

/** Why a command name can't be used, or nil when it can. */
func accountNameProblem(_ k: AccountKind, _ name: String) -> String? {
  if name.isEmpty { return "Type a name." }
  if name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) == nil {
    return "Use only letters, digits, - and _."
  }
  guard let dir = accountDir(k, name) else { return "Pick a name other than \(k.command)." }
  if commandExists(name) { return "A command named \(name) already exists." }
  if FileManager.default.fileExists(atPath: dir) {
    return "The folder ~/\((dir as NSString).lastPathComponent) already exists."
  }
  return nil
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// ---- app -------------------------------------------------------------------------

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  let model = Model()
  var panel: Panel!
  var status: NSStatusItem!
  var topItem: NSMenuItem!
  var loginItem: NSMenuItem!
  var settingsPanel: Panel?
  var settingsSink: AnyCancellable?
  var bag = Set<AnyCancellable>()

  func applicationDidFinishLaunching(_ note: Notification) {
    let host = HostingView(
      rootView: WidgetView(
        m: model, settings: { [weak self] in self?.showSettings() }, add: { [weak self] in self?.showAddMenu() },
        hide: { [weak self] in self?.toggleWindow() }))
    host.frame.size = host.fittingSize

    panel = Panel(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.contentView = host
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let topmost = defaults.object(forKey: "topmost") as? Bool ?? true
    panel.level = topmost ? .floating : .normal

    let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    if let right = defaults.object(forKey: "right") as? Double, let top = defaults.object(forKey: "top") as? Double {
      panel.setFrameTopLeftPoint(NSPoint(x: right - host.fittingSize.width, y: top))
    } else if let x = defaults.object(forKey: "x") as? Double, let top = defaults.object(forKey: "top") as? Double {
      panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    } else {
      panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - 330, y: area.maxY - 16))
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
      [weak self] _ in
      guard let f = self?.panel.frame else { return }
      defaults.set(Double(f.minX), forKey: "x")
      defaults.set(Double(f.maxY), forKey: "top")
      // On the right half of the screen the right edge is what stays put, also across restarts.
      let area = self?.panel.screen?.visibleFrame ?? f
      if f.midX > area.midX { defaults.set(Double(f.maxX), forKey: "right") } else { defaults.removeObject(forKey: "right") }
    }

    // Grow or shrink with the content, keeping the top edge where the user put it, and the right edge
    // on the right half of the screen (the strip then grows leftward).
    model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        let size = host.fittingSize
        let f = self.panel.frame
        let area = self.panel.screen?.visibleFrame ?? f
        let x = f.midX > area.midX ? f.maxX - size.width : f.minX
        self.panel.setFrame(NSRect(x: x, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
        self.status.button?.toolTip = self.model.trayText
      }
    }.store(in: &bag)

    setupStatusItem(topmost: topmost)

    // A second launch asks this instance to show itself.
    DistributedNotificationCenter.default().addObserver(forName: showNotification, object: nil, queue: .main) {
      [weak self] _ in self?.showWindow()
    }

    Timer.scheduledTimer(withTimeInterval: refreshMinutes * 60, repeats: true) { [weak self] _ in
      self?.model.refresh()
    }

    // Look for a new version at start and once a day; the gear gets a dot when there is one.
    Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
      self?.model.runUpdate("check")
    }

    panel.alphaValue = 0
    showWindow()
    model.detect()
    model.runUpdate("check")
  }

  func setupStatusItem(topmost: Bool) {
    status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let img = NSImage(systemSymbolName: "gauge", accessibilityDescription: "OpenUsage") {
      img.isTemplate = true
      status.button?.image = img
    } else {
      status.button?.title = "\u{25F7}"
    }
    status.button?.toolTip = model.trayText

    let menu = NSMenu()
    menu.delegate = self
    menu.addItem(withTitle: "Show / hide", action: #selector(toggleWindow), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",").target = self
    for item in addItems() { menu.addItem(item) }
    menu.addItem(.separator())
    topItem = menu.addItem(withTitle: "Always on top", action: #selector(toggleTopmost), keyEquivalent: "")
    topItem.target = self
    topItem.state = topmost ? .on : .off
    loginItem = menu.addItem(withTitle: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
    loginItem.target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    status.menu = menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    loginItem.state = FileManager.default.fileExists(atPath: agentURL.path) ? .on : .off
  }

  var hiding = false

  /** Opening: the widget fades in while settling the last few points into place. */
  func showWindow() {
    hiding = false
    if panel.isVisible && panel.alphaValue == 1 {
      panel.orderFrontRegardless()
      return
    }
    let f = panel.frame
    panel.alphaValue = 0
    panel.setFrameOrigin(NSPoint(x: f.minX, y: f.minY - 8))
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.24
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
      panel.animator().setFrame(f, display: true)
    }
  }

  /** Closing: a quick fade, then hidden. */
  func hideWindow() {
    if hiding { return }
    hiding = true
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.16
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      guard let self, self.hiding else { return }
      self.hiding = false
      self.panel.orderOut(nil)
      self.panel.alphaValue = 1
    })
  }

  @objc func toggleWindow() {
    if panel.isVisible && !hiding { hideWindow() } else { showWindow() }
  }

  @objc func refresh() { model.refresh() }

  /** Settings open in a panel beside the widget, styled like it. */
  @objc func showSettings() {
    if let p = settingsPanel {
      p.orderFrontRegardless()
      return
    }
    model.runKeys([])
    let host = HostingView(
      rootView: SettingsView(
        m: model, close: { [weak self] in self?.closeSettings() }, askKey: { [weak self] in self?.askKey($0) }))
    let size = host.fittingSize
    host.frame.size = size
    let p = Panel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.contentView = host
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.hidesOnDeactivate = false
    p.level = .floating
    let f = panel.frame
    let area = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
    let x = f.minX - size.width - 8 >= area.minX ? f.minX - size.width - 8 : f.maxX + 8
    p.setFrameTopLeftPoint(NSPoint(x: x, y: f.maxY))
    // The status line can wrap: keep the top edge and follow the content height.
    settingsSink = model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let p = self?.settingsPanel else { return }
        let s = host.fittingSize
        p.setFrame(NSRect(x: p.frame.minX, y: p.frame.maxY - s.height, width: s.width, height: s.height), display: true)
      }
    }
    settingsPanel = p
    p.orderFrontRegardless()
  }

  func closeSettings() {
    settingsPanel?.orderOut(nil)
    settingsPanel = nil
  }

  func addItems() -> [NSMenuItem] {
    accountKinds.map { k in
      let item = NSMenuItem(title: "Add \(k.name) account\u{2026}", action: #selector(addAccount(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = k.id
      return item
    }
  }

  func showAddMenu() {
    let menu = NSMenu()
    for item in addItems() { menu.addItem(item) }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  @objc func addAccount(_ sender: NSMenuItem) {
    guard let k = accountKinds.first(where: { $0.id == sender.representedObject as? String }),
      let root = resource("root")
    else { return }
    var n = 2
    while accountNameProblem(k, "\(k.command)\(n)") != nil { n += 1 }
    guard let name = askAccountName(k, suggested: "\(k.command)\(n)") else { return }

    // Terminal runs the script through a .command file, which needs no Automation permission.
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("openusage-add-\(UUID().uuidString)")
    let done = base.appendingPathExtension("done")
    let file = base.appendingPathExtension("command")
    let node = resource("node").flatMap { FileManager.default.isExecutableFile(atPath: $0) ? shellQuote($0) : nil } ?? "node"
    let lines = [
      "#!/bin/zsh -l",
      "cd \(shellQuote(root))",
      "\(node) --experimental-strip-types --no-warnings scripts/add-account.ts \(k.id) \(shellQuote(name))",
      "rc=$?",
      "touch \(shellQuote(done.path))",
      "[ $rc -ne 0 ] && read '?Press Enter to close'",
      "exit $rc",
    ]
    do {
      try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    } catch {
      model.lastError = "could not add account"
      return
    }
    NSWorkspace.shared.open(file)

    // When the terminal is done, fetch again so the new account shows up.
    var waited = 0.0
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
      waited += 3
      if FileManager.default.fileExists(atPath: done.path) {
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.removeItem(at: file)
        self?.model.refresh()
        t.invalidate()
      } else if waited > 30 * 60 {
        t.invalidate()
      }
    }
  }

  /** Asks for an API key, checks it with the service, keeps it and fetches again; asks again on a bad key. */
  func askKey(_ pid: String) {
    let info = model.keys[pid]
    let name = info?.name ?? pid
    let alert = NSAlert()
    alert.messageText = "\(name) API key"
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    if info?.url != nil { alert.addButton(withTitle: "Create a key\u{2026}") }
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    let intro = "\(name) has no app sign-in to read, so it needs an API key. It stays on this Mac and goes to \(name) alone."
    var note = intro
    while true {
      alert.informativeText = note
      let response = alert.runModal()
      if response == .alertThirdButtonReturn {
        if let url = info.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(url) }
        continue
      }
      guard response == .alertFirstButtonReturn else { return }
      let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty else {
        note = "Paste a key.\n\n\(intro)"
        continue
      }
      // The check runs in node; keep the run loop turning (and this prompt away) until it answers.
      var error: String?
      guard model.runKeys(["set", pid], key: key, done: { error = $0 }) else {
        note = "Busy, try again in a moment.\n\n\(intro)"
        continue
      }
      while error == nil { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1)) }
      if let error, !error.isEmpty {
        note = "\(error)\n\n\(intro)"
        continue
      }
      model.refresh()
      return
    }
  }

  /** Native prompt for the new account's command name; nil when cancelled. */
  func askAccountName(_ k: AccountKind, suggested: String) -> String? {
    let alert = NSAlert()
    alert.messageText = "Add \(k.name) account"
    alert.addButton(withTitle: "Sign in")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = suggested
    field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    let intro = "Command that opens this account from any terminal."
    var note = intro
    while true {
      alert.informativeText = note
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      let name = field.stringValue.trimmingCharacters(in: .whitespaces)
      guard let problem = accountNameProblem(k, name) else { return name }
      note = "\(problem)\n\n\(intro)"
    }
  }

  @objc func toggleTopmost() {
    let on = panel.level != .floating
    panel.level = on ? .floating : .normal
    topItem.state = on ? .on : .off
    defaults.set(on, forKey: "topmost")
  }

  @objc func toggleLogin() {
    setStartAtLogin(!FileManager.default.fileExists(atPath: agentURL.path))
  }

  // `open -a OpenUsage` on a running copy lands here instead of starting a second one.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    showWindow()
    return false
  }
}

let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
  .filter { $0 != NSRunningApplication.current }
if !others.isEmpty {
  DistributedNotificationCenter.default().postNotificationName(
    showNotification, object: nil, userInfo: nil, deliverImmediately: true)
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
