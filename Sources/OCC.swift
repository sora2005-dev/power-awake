import AppKit
import Foundation

private let configURL = URL(fileURLWithPath: "/Library/Application Support/occ/config.json")

struct AwakeConfig: Codable, Equatable {
  var enabled: Bool
  var onlyWhilePluggedIn: Bool
  var sleepOnPowerDisconnect: Bool
  var allowDisplaySleep: Bool
  var sleepDisplayWhenLidClosed: Bool
  var preventLidSleep: Bool
  var activeUntil: String?
  var blockDays: String

  enum CodingKeys: String, CodingKey {
    case enabled
    case onlyWhilePluggedIn
    case sleepOnPowerDisconnect
    case allowDisplaySleep
    case sleepDisplayWhenLidClosed
    case preventLidSleep
    case activeUntil
    case blockDays
  }

  init(
    enabled: Bool = true,
    onlyWhilePluggedIn: Bool = true,
    sleepOnPowerDisconnect: Bool = true,
    allowDisplaySleep: Bool = true,
    sleepDisplayWhenLidClosed: Bool = true,
    preventLidSleep: Bool = true,
    activeUntil: String? = nil,
    blockDays: String = "none"
  ) {
    self.enabled = enabled
    self.onlyWhilePluggedIn = onlyWhilePluggedIn
    self.sleepOnPowerDisconnect = sleepOnPowerDisconnect
    self.allowDisplaySleep = allowDisplaySleep
    self.sleepDisplayWhenLidClosed = sleepDisplayWhenLidClosed
    self.preventLidSleep = preventLidSleep
    self.activeUntil = activeUntil
    self.blockDays = blockDays
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    onlyWhilePluggedIn = try container.decodeIfPresent(Bool.self, forKey: .onlyWhilePluggedIn) ?? true
    sleepOnPowerDisconnect = try container.decodeIfPresent(Bool.self, forKey: .sleepOnPowerDisconnect) ?? true
    allowDisplaySleep = try container.decodeIfPresent(Bool.self, forKey: .allowDisplaySleep) ?? true
    sleepDisplayWhenLidClosed = try container.decodeIfPresent(Bool.self, forKey: .sleepDisplayWhenLidClosed) ?? true
    preventLidSleep = try container.decodeIfPresent(Bool.self, forKey: .preventLidSleep) ?? true
    activeUntil = try container.decodeIfPresent(String.self, forKey: .activeUntil)
    blockDays = try container.decodeIfPresent(String.self, forKey: .blockDays) ?? "none"
  }
}

enum ProbeState {
  case unknown
  case ok(String)
  case warning(String)
  case failed(String)

  var color: NSColor {
    switch self {
    case .ok:
      return .systemGreen
    case .warning:
      return .systemYellow
    case .failed:
      return .systemRed
    case .unknown:
      return .systemGray
    }
  }

  var text: String {
    switch self {
    case .ok(let value), .warning(let value), .failed(let value):
      return value
    case .unknown:
      return "不明"
    }
  }

  var isFailed: Bool {
    if case .failed = self {
      return true
    }
    return false
  }
}

final class AwakeStore {
  var config = AwakeConfig()
  var power = ProbeState.unknown
  var sleepGuard = ProbeState.unknown
  var lastError: String?

  func load() {
    do {
      let data = try Data(contentsOf: configURL)
      config = try JSONDecoder().decode(AwakeConfig.self, from: data)
      lastError = nil
    } catch {
      config = AwakeConfig()
      lastError = "設定を読めません"
    }
    refreshLocalStatus()
  }

  func save() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(config)
      try data.write(to: configURL, options: .atomic)
      lastError = nil
      load()
    } catch {
      lastError = "設定を書けません"
    }
  }

  func refreshLocalStatus() {
    power = currentPowerState()
    sleepGuard = currentSleepGuard()
  }

  func setDuration(minutes: Int?) {
    if let minutes {
      let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
      config.activeUntil = ISO8601DateFormatter().string(from: until)
      config.enabled = true
    } else {
      config.activeUntil = nil
      config.enabled = true
    }
    save()
  }

  func durationLabel() -> String {
    guard let activeUntil = config.activeUntil else {
      return "継続時間: 無制限"
    }
    let formatter = ISO8601DateFormatter()
    guard let until = formatter.date(from: activeUntil) else {
      return "有効期限: 不明"
    }
    let remaining = Int(until.timeIntervalSinceNow)
    if remaining <= 0 {
      return "有効期限: 期限切れ"
    }
    let hours = remaining / 3600
    let minutes = max(1, (remaining % 3600 + 59) / 60)
    if hours > 0 {
      return "残り: \(hours)時間\(minutes)分"
    }
    return "残り: \(minutes)分"
  }

  func turnDisplayOffNow() {
    DispatchQueue.global(qos: .utility).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      process.arguments = ["displaysleepnow"]
      try? process.run()
    }
  }

  private func currentPowerState() -> ProbeState {
    let output = runCapture("/usr/bin/pmset", ["-g", "batt"])
    if output.contains("AC Power") {
      return .ok("外部電源")
    }
    if output.contains("Battery Power") {
      return config.onlyWhilePluggedIn ? .warning("バッテリー") : .ok("バッテリー許可")
    }
    return .unknown
  }

  private func currentSleepGuard() -> ProbeState {
    if !config.enabled {
      return .warning("防止OFF")
    }
    let output = runCapture("/usr/sbin/ioreg", ["-r", "-k", "SleepDisabled", "-d", "1"])
    if output.contains("\"SleepDisabled\" = Yes") {
      return .ok("閉じても維持")
    }
    if config.preventLidSleep && config.enabled {
      return .warning("反映待ち")
    }
    return .unknown
  }

  private func runCapture(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      if !process.waitUntilExit(timeout: 4) {
        process.terminate()
      }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return String(data: data, encoding: .utf8) ?? ""
    } catch {
      return ""
    }
  }
}

extension Process {
  func waitUntilExit(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    return !isRunning
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let store = AwakeStore()
  private var statusItem: NSStatusItem!
  private var refreshTimer: Timer?
  private var liveMenuTimer: Timer?
  private var powerItem: NSMenuItem?
  private var sleepGuardItem: NSMenuItem?
  private var sleepPreventionItem: NSMenuItem?
  private var onlyWhilePluggedInItem: NSMenuItem?
  private var sleepOnPowerDisconnectItem: NSMenuItem?
  private var allowDisplaySleepItem: NSMenuItem?
  private var sleepDisplayWhenLidClosedItem: NSMenuItem?
  private var preventLidSleepItem: NSMenuItem?
  private var untilItem: NSMenuItem?
  private var errorItem: NSMenuItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    store.load()

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = nil
    statusItem.button?.title = "OCC"
    statusItem.button?.toolTip = "OCC スリープ制御"
    rebuildMenu()

    refreshTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
      self?.store.load()
      self?.updateMenuItems()
    }
    if let refreshTimer {
      RunLoop.main.add(refreshTimer, forMode: .common)
    }

    liveMenuTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.store.load()
      self?.updateMenuItems()
    }
    if let liveMenuTimer {
      RunLoop.main.add(liveMenuTimer, forMode: .common)
    }
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false

    powerItem = statusItem("電源", store.power)
    sleepGuardItem = statusItem("スリープ防止", store.sleepGuard)
    menu.addItem(powerItem!)
    menu.addItem(sleepGuardItem!)
    menu.addItem(.separator())

    sleepPreventionItem = toggle("スリープ防止を有効化", state: store.config.enabled, action: #selector(toggleEnabled))
    onlyWhilePluggedInItem = toggle("電源接続中のみ", state: store.config.onlyWhilePluggedIn, action: #selector(toggleOnlyWhilePluggedIn))
    sleepOnPowerDisconnectItem = toggle("電源を抜いたらスリープ", state: store.config.sleepOnPowerDisconnect, action: #selector(toggleSleepOnPowerDisconnect))
    allowDisplaySleepItem = toggle("画面オフを許可", state: store.config.allowDisplaySleep, action: #selector(toggleAllowDisplaySleep))
    sleepDisplayWhenLidClosedItem = toggle("閉じたら画面オフ", state: store.config.sleepDisplayWhenLidClosed, action: #selector(toggleSleepDisplayWhenLidClosed))
    preventLidSleepItem = toggle("閉じてもスリープしない", state: store.config.preventLidSleep, action: #selector(togglePreventLidSleep))
    menu.addItem(sleepPreventionItem!)
    menu.addItem(onlyWhilePluggedInItem!)
    menu.addItem(sleepOnPowerDisconnectItem!)
    menu.addItem(allowDisplaySleepItem!)
    menu.addItem(sleepDisplayWhenLidClosedItem!)
    menu.addItem(preventLidSleepItem!)
    menu.addItem(.separator())

    let duration = NSMenuItem(title: "継続時間", action: nil, keyEquivalent: "")
    let durationMenu = NSMenu()
    durationMenu.addItem(actionItem("無制限", #selector(durationUnlimited)))
    durationMenu.addItem(actionItem("30分", #selector(duration30)))
    durationMenu.addItem(actionItem("1時間", #selector(duration60)))
    durationMenu.addItem(actionItem("2時間", #selector(duration120)))
    duration.submenu = durationMenu
    menu.addItem(duration)

    untilItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    untilItem?.isEnabled = true
    menu.addItem(untilItem!)
    menu.addItem(.separator())

    menu.addItem(actionItem("今すぐ画面をオフ", #selector(turnDisplayOffNow)))

    errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    errorItem?.isEnabled = false
    menu.addItem(errorItem!)

    menu.addItem(.separator())
    menu.addItem(actionItem("終了", #selector(quit)))
    statusItem.menu = menu
    updateMenuItems()
  }

  func menuWillOpen(_ menu: NSMenu) {
    store.load()
    updateMenuItems()
  }

  private func updateMenuItems() {
    statusItem.button?.image = nil
    statusItem.button?.title = store.sleepGuard.isFailed ? "OCC!" : "OCC"
    updateStatusItem(powerItem, title: "電源", state: store.power)
    updateStatusItem(sleepGuardItem, title: "スリープ防止", state: store.sleepGuard)
    sleepPreventionItem?.state = store.config.enabled ? .on : .off
    onlyWhilePluggedInItem?.state = store.config.onlyWhilePluggedIn ? .on : .off
    sleepOnPowerDisconnectItem?.state = store.config.sleepOnPowerDisconnect ? .on : .off
    allowDisplaySleepItem?.state = store.config.allowDisplaySleep ? .on : .off
    sleepDisplayWhenLidClosedItem?.state = store.config.sleepDisplayWhenLidClosed ? .on : .off
    preventLidSleepItem?.state = store.config.preventLidSleep ? .on : .off
    untilItem?.title = store.durationLabel()
    errorItem?.title = store.lastError ?? ""
    errorItem?.isHidden = store.lastError == nil
  }

  private func updateStatusItem(_ item: NSMenuItem?, title: String, state: ProbeState) {
    item?.title = "\(title): \(state.text)"
    item?.image = dotImage(state.color)
  }

  private func statusItem(_ title: String, _ state: ProbeState) -> NSMenuItem {
    let item = NSMenuItem(title: "\(title): \(state.text)", action: nil, keyEquivalent: "")
    item.image = dotImage(state.color)
    item.isEnabled = true
    return item
  }

  private func toggle(_ title: String, state: Bool, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.state = state ? .on : .off
    return item
  }

  private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func dotImage(_ color: NSColor) -> NSImage {
    let size = NSSize(width: 9, height: 9)
    let image = NSImage(size: size)
    image.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    image.unlockFocus()
    image.isTemplate = false
    return image
  }

  private func saveAndRefresh() {
    store.save()
    updateMenuItems()
  }

  @objc private func toggleEnabled() {
    store.config.enabled.toggle()
    saveAndRefresh()
  }

  @objc private func toggleOnlyWhilePluggedIn() {
    store.config.onlyWhilePluggedIn.toggle()
    saveAndRefresh()
  }

  @objc private func toggleSleepOnPowerDisconnect() {
    store.config.sleepOnPowerDisconnect.toggle()
    saveAndRefresh()
  }

  @objc private func toggleAllowDisplaySleep() {
    store.config.allowDisplaySleep.toggle()
    saveAndRefresh()
  }

  @objc private func toggleSleepDisplayWhenLidClosed() {
    store.config.sleepDisplayWhenLidClosed.toggle()
    saveAndRefresh()
  }

  @objc private func togglePreventLidSleep() {
    store.config.preventLidSleep.toggle()
    saveAndRefresh()
  }

  @objc private func durationUnlimited() {
    store.setDuration(minutes: nil)
    updateMenuItems()
  }

  @objc private func duration30() {
    store.setDuration(minutes: 30)
    updateMenuItems()
  }

  @objc private func duration60() {
    store.setDuration(minutes: 60)
    updateMenuItems()
  }

  @objc private func duration120() {
    store.setDuration(minutes: 120)
    updateMenuItems()
  }

  @objc private func turnDisplayOffNow() {
    store.turnDisplayOffNow()
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
