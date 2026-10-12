// Floating Claude / Codex / Cursor / OpenCode Go usage widget for macOS.
// Plain AppKit + SwiftUI, compiled on the user's Mac by build.sh: nothing to download.
// Data comes from ../scripts/usage-json.ts, run with Node (>= 22.6).

import AppKit
import Combine
import SwiftUI

let refreshMinutes = 5.0
let bundleId = "com.openusage.widget"
let showNotification = Notification.Name("com.openusage.widget.show")
let icons = ["claude": "\u{273B}", "codex": "\u{25CE}", "copilot": "\u{25C8}", "cursor": "\u{2B21}", "kilo": "\u{25C6}", "opencode-go": "\u{25A3}"]

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
  @Published var layout = defaults.string(forKey: "layout") == "compact" ? "compact" : "normal"
  @Published var update = UpdateState()

  private var proc: Process?
  private var updateProc: Process?

  init() {
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

  /** Runs scripts/<name> with node and hands its stdout to `done` on the main thread; nil when it can't start. */
  func runScript(_ name: String, _ args: [String], timeout: Double, done: @escaping (Data, Bool) -> Void) -> Process? {
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
    guard proc == nil else { return }
    guard resource("root") != nil else {
      lastError = "run build.sh again"
      return
    }
    proc = runScript("usage-json.ts", [], timeout: 60) { raw, timedOut in self.complete(raw, timedOut: timedOut) }
    if proc == nil {
      lastError = "node not found"
      return
    }
    refreshing = true
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
    if layout != "compact" { return data }
    return data.filter { $0.account != nil || !$0.windows.isEmpty || !$0.extras.isEmpty || $0.error == nil }
  }

  var trayText: String {
    let parts = data.compactMap { u -> String? in
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

let accents: [String: Color] = ["claude": themed(0xD97757, 0xD97757), "codex": themed(0x0F8A6C, 0x3DBE9C), "copilot": themed(0x8250DF, 0xA371F7), "kilo": themed(0xA68A00, 0xF2D33C)]

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
  let action: () -> Void
  @StateObject private var hover = LocalState(false)

  var body: some View {
    Button(action: action) {
      Text(title)
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
}

struct Bar: View {
  let pct: Double
  let color: Color

  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(C.track)
        Capsule().fill(color).frame(width: g.size.width * CGFloat(max(0, min(100, pct))) / 100)
      }
    }
    .frame(height: 4)
  }
}

struct Card: View {
  let u: ProviderUsage
  let display: String

  var body: some View {
    let hasData = !u.windows.isEmpty || !u.extras.isEmpty
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        (Text("\(icons[u.id] ?? "")  ").foregroundColor(C.muted) + Text(u.name))
          .font(.system(size: 13.5, weight: .semibold))
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
        Bar(pct: w.usedPct, color: lv ?? C.muted).padding(.top, 5)
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
  // Arcs grow from zero when the ring first appears, then follow new values.
  @StateObject private var appeared = LocalState(false)

  var body: some View {
    let s = slots(u)
    let t: CGFloat = 4
    let inner = size - 2 * (t + 3)
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
      }
    }
    .frame(width: size, height: size)
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

  var body: some View {
    let first = g.accounts[0]
    let name = first.name.replacingOccurrences(of: " \\(.*\\)$", with: "", options: .regularExpression)
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        (Text("\(icons[g.id] ?? "")  ").foregroundColor(accents[g.id] ?? C.muted) + Text(name))
          .font(.system(size: 13.5, weight: .semibold))
        Spacer()
        Text(g.accounts.count > 1 ? "\(g.accounts.count) accounts" : (first.plan?.uppercased() ?? ""))
          .font(.system(size: 10.5, weight: .semibold)).foregroundColor(C.muted)
      }
      VStack(alignment: .leading, spacing: 0) {
        ForEach(g.accounts, id: \.uid) { AccountRow(u: $0, display: display) }
      }
      .padding(.top, 6)
    }
    .padding(EdgeInsets(top: 10, leading: 12, bottom: 6, trailing: 12))
    .background(RoundedRectangle(cornerRadius: 10).fill(C.card))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(C.cardBorder, lineWidth: 1))
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

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { o in
        let on = o.value == value
        Button {
          pick(o.value)
        } label: {
          Text(o.label)
            .font(.system(size: 12.5, weight: on ? .semibold : .regular))
            .foregroundColor(on ? C.bg : C.muted)
            .frame(minWidth: 62)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? C.text : Color.clear))
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
      caption("DISPLAY")
      option("Numbers", "Default for every limit") {
        Segmented(
          options: [SegOption(value: "used", label: "Used"), SegOption(value: "remaining", label: "Left")],
          value: m.display, pick: { m.setDisplay($0) })
      }
      option("Layout", "Compact: a line per account") {
        Segmented(
          options: [SegOption(value: "normal", label: "Normal"), SegOption(value: "compact", label: "Compact")],
          value: m.layout, pick: { m.setLayout($0) })
      }
      .padding(.top, 8)
      Rectangle().fill(C.divider).frame(height: 1).padding(.top, 16).padding(.bottom, 14)
      caption("ABOUT")
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
        HeaderButton(title: "\u{27F3}", help: "Refresh") { m.refresh() }
        HeaderButton(title: "\u{2715}", help: "Hide (menu bar icon brings it back)", action: hide)
      }
      .padding(.bottom, 8)
      .background(DragArea())
      Rectangle().fill(C.divider).frame(height: 1).padding(.bottom, 8)
      if m.shown.isEmpty {
        Text(m.refreshing ? "Loading..." : "No data").foregroundColor(C.muted)
      }
      VStack(spacing: 8) {
        if m.layout == "compact" {
          ForEach(groups(m.shown)) { CompactCard(g: $0, display: m.display) }
        } else {
          ForEach(m.shown, id: \.uid) { Card(u: $0, display: m.display) }
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
    if let x = defaults.object(forKey: "x") as? Double, let top = defaults.object(forKey: "top") as? Double {
      panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
    } else {
      panel.setFrameTopLeftPoint(NSPoint(x: area.maxX - 330, y: area.maxY - 16))
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) {
      [weak self] _ in
      guard let f = self?.panel.frame else { return }
      defaults.set(Double(f.minX), forKey: "x")
      defaults.set(Double(f.maxY), forKey: "top")
    }

    // Grow or shrink with the content, keeping the top edge where the user put it.
    model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        let size = host.fittingSize
        let top = self.panel.frame.maxY
        self.panel.setFrame(
          NSRect(x: self.panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
          display: true)
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

    panel.orderFrontRegardless()
    model.refresh()
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

  func showWindow() {
    panel.orderFrontRegardless()
  }

  @objc func toggleWindow() {
    if panel.isVisible { panel.orderOut(nil) } else { showWindow() }
  }

  @objc func refresh() { model.refresh() }

  /** Settings open in a panel beside the widget, styled like it. */
  @objc func showSettings() {
    if let p = settingsPanel {
      p.orderFrontRegardless()
      return
    }
    let host = HostingView(rootView: SettingsView(m: model, close: { [weak self] in self?.closeSettings() }))
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
