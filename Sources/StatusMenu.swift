import AppKit
import Combine

/// The menu bar item shown while a phone is mirrored, so it is always clear when
/// one is: how it is connected, its battery, and the quick actions.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
  static let shared = StatusMenu()

  private var item: NSStatusItem?
  private var watching: AnyCancellable?

  func start() {
    let mirrors = MirrorManager.shared
    let menuBarNotifications = MenuBarNotifications.shared
    let notifications = menuBarNotifications.$enabled.combineLatest(menuBarNotifications.$count)
    watching = Publishers.CombineLatest4(
      mirrors.$live, mirrors.$recording, DeviceHub.shared.$phones, notifications
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] live, recording, phones, notificationState in
      let (enabled, count) = notificationState
      self?.update(
        live: live, recording: recording, showsCounter: enabled && !phones.isEmpty,
        count: enabled ? count : 0)
    }
  }

  private func update(live: [Phone], recording: Bool, showsCounter: Bool, count: Int) {
    guard !live.isEmpty || showsCounter else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      return
    }
    if item == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let menu = NSMenu()
      menu.delegate = self
      item.menu = menu
      self.item = item
      PhoneBattery.shared.refresh()
    }
    let symbol = recording ? "record.circle" : "iphone.radiowaves.left.and.right"
    let image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: "PixelMirror")
    image?.isTemplate = true
    item?.button?.image = image
    let showsCount = showsCounter && count > 0
    item?.length = showsCount ? NSStatusItem.variableLength : NSStatusItem.squareLength
    item?.button?.imagePosition = showsCount ? .imageLeft : .imageOnly
    item?.button?.title = showsCount ? count.formatted() : ""
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let hub = DeviceHub.shared
    let mirrors = MirrorManager.shared
    for phone in mirrors.live {
      menu.addItem(.sectionHeader(title: phone.name))
      if hub.phones.contains(where: { $0.id == phone.id }) {
        menu.addItem(
          info(
            phone.isUSB ? String(localized: "USB") : String(localized: "Wi-Fi"),
            phone.isUSB ? "cable.connector" : "wifi"))
        if let level = PhoneBattery.shared.levels[phone.id] {
          let percent = level.percent.formatted(.percent)
          menu.addItem(
            info(
              level.charging
                ? String(localized: "Charging, \(percent)")
                : String(localized: "Battery \(percent)"), level.symbol))
        }
      } else {
        menu.addItem(info(String(localized: "Waiting for \(phone.name)…"), "hourglass"))
      }
      let controller = mirrors.controller(for: phone)
      menu.addItem(action(String(localized: "Show")) { mirrors.open(phone) })
      menu.addItem(action(String(localized: "Open App…")) { AppPicker.shared.show(for: phone) })
      let computer = action(String(localized: "Computer Mode")) { mirrors.toggleComputer(phone) }
      computer.state = mirrors.computers.contains(phone.id) ? .on : .off
      menu.addItem(computer)
      menu.addItem(action(String(localized: "Take Screenshot")) { controller?.takeScreenshot() })
      menu.addItem(
        action(
          controller?.isRecording == true
            ? String(localized: "Stop Recording") : String(localized: "Record Screen")
        ) { controller?.toggleRecording() })
      if Webcam.canInstall {
        let webcam = action(String(localized: "Use as Webcam")) { Webcam.shared.toggle(phone) }
        webcam.state = Webcam.shared.phoneID == phone.id ? .on : .off
        menu.addItem(webcam)
      }
      menu.addItem(action(String(localized: "Stop Mirroring")) { mirrors.stop(phone) })
      menu.addItem(.separator())
    }
    if MenuBarNotifications.shared.count > 0 {
      menu.addItem(
        action(String(localized: "Clear notification count")) {
          MenuBarNotifications.shared.clear()
        })
      menu.addItem(.separator())
    }
    menu.addItem(action(String(localized: "Quit PixelMirror")) { NSApp.terminate(nil) })
    PhoneBattery.shared.refresh()
  }

  private func info(_ title: String, _ symbol: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    item.isEnabled = false
    return item
  }

  private func action(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
    let item = ClosureMenuItem(
      title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
    item.target = item
    item.run = run
    return item
  }
}

private final class ClosureMenuItem: NSMenuItem {
  var run: (() -> Void)?
  @objc func fire() { run?() }
}

/// The battery of each mirrored phone, read with adb now and then.
@MainActor
final class PhoneBattery: ObservableObject {
  static let shared = PhoneBattery()

  struct Level: Equatable {
    var percent: Int
    var charging: Bool

    var symbol: String {
      if charging { return "battery.100.bolt" }
      switch percent {
      case 88...: return "battery.100"
      case 63..<88: return "battery.75"
      case 38..<63: return "battery.50"
      case 13..<38: return "battery.25"
      default: return "battery.0"
      }
    }
  }

  @Published private(set) var levels: [String: Level] = [:]
  private var timer: Timer?
  private var reading: Set<String> = []

  private init() {
    timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      Task { @MainActor in PhoneBattery.shared.refresh() }
    }
  }

  func refresh() {
    let present = Set(DeviceHub.shared.phones.map(\.id))
    levels = levels.filter { present.contains($0.key) }
    for phone in MirrorManager.shared.live
    where present.contains(phone.id) && !reading.contains(phone.id) {
      reading.insert(phone.id)
      let transport = phone.transport
      DispatchQueue.global().async {
        let result = ADB.run(["-s", transport, "shell", "dumpsys battery"], timeout: 8)
        let level = result.ok ? Self.parse(result.output) : nil
        DispatchQueue.main.async {
          self.reading.remove(phone.id)
          if let level { self.levels[phone.id] = level }
        }
      }
    }
  }

  nonisolated static func parse(_ output: String) -> Level? {
    var fields: [String: String] = [:]
    for line in output.split(separator: "\n") {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      fields[parts[0].trimmingCharacters(in: .whitespaces)] =
        parts[1].trimmingCharacters(in: .whitespaces)
    }
    guard let percent = fields["level"].flatMap(Int.init) else { return nil }
    // 2 is charging, 5 is full and still plugged in.
    let status = fields["status"].flatMap(Int.init) ?? 0
    return Level(percent: percent, charging: status == 2 || status == 5)
  }
}
