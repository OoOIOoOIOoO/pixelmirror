import AppKit
import SwiftUI
import UserNotifications

/// Shows the phone's new notifications in Notification Center. Read on the Mac
/// with adb every few seconds; nothing leaves this Mac.
@MainActor
final class PhoneNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  static let shared = PhoneNotifications()
  static let key = "showsPhoneNotifications"

  @Published private(set) var denied = false
  private var timer: Timer?
  private var reading: Set<String> = []
  /// What each phone has already shown, by notification key and update time.
  private var seen: [String: Set<String>] = [:]

  private var enabled: Bool {
    UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true
  }

  func start() {
    UNUserNotificationCenter.current().delegate = self
    refreshAuthorization()
    timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  func refreshAuthorization() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let denied = settings.authorizationStatus == .denied
      DispatchQueue.main.async { self.denied = denied }
    }
  }

  private func poll() {
    let phones = DeviceHub.shared.phones
    for id in seen.keys where !phones.contains(where: { $0.id == id }) { seen[id] = nil }
    guard enabled else { return }
    for phone in phones where !reading.contains(phone.id) {
      reading.insert(phone.id)
      let transport = phone.transport
      DispatchQueue.global().async {
        let list = Self.read(transport)
        DispatchQueue.main.async {
          self.reading.remove(phone.id)
          self.received(list, from: phone)
        }
      }
    }
  }

  private func received(_ list: [Item]?, from phone: Phone) {
    guard let list, enabled else { return }
    let signatures = Set(list.map(\.signature))
    // The first read only learns what is already there.
    guard let known = seen[phone.id] else {
      seen[phone.id] = signatures
      return
    }
    seen[phone.id] = signatures
    let knownKeys = Set(known.map { String($0.prefix { $0 != "@" }) })
    // An app updating a notification quietly (a download, a call timer) is not news.
    let fresh = list.filter {
      !known.contains($0.signature) && !($0.alertsOnce && knownKeys.contains($0.key))
    }
    guard !fresh.isEmpty else { return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
      DispatchQueue.main.async { self.refreshAuthorization() }
    }
    for item in fresh { post(item, from: phone) }
  }

  private func post(_ item: Item, from phone: Phone) {
    let content = UNMutableNotificationContent()
    content.title = item.app
    if let title = item.title { content.subtitle = title }
    if let text = item.text { content.body = text }
    content.sound = .default
    content.threadIdentifier = item.package
    content.userInfo = ["package": item.package, "app": item.app, "phone": phone.id]
    let request = UNNotificationRequest(
      identifier: "\(phone.id)|\(item.signature)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  // MARK: - Clicks

  /// Opens the app the notification came from, in a window of its own.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let package = info["package"] as? String
    let label = info["app"] as? String
    let phoneID = info["phone"] as? String
    DispatchQueue.main.async {
      let phones = DeviceHub.shared.phones
      if let phone = phones.first(where: { $0.id == phoneID }) ?? phones.first {
        if let package {
          MirrorManager.shared.open(PhoneApp(package: package, label: label ?? package), on: phone)
        } else {
          MirrorManager.shared.open(phone)
        }
      }
      completionHandler()
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }

  // MARK: - Reading the phone's notifications

  struct Item {
    var package: String
    var app: String
    var title: String?
    var text: String?
    var key: String
    var alertsOnce: Bool
    var signature: String { "\(key)@\(updated)" }
    var updated: String
  }

  /// nil when the phone could not be read, so nothing is mistaken for new.
  nonisolated private static func read(_ transport: String) -> [Item]? {
    let filter =
      "^    NotificationRecord|^      flags=|android\\.(title|text|appLabel)=|^      mUpdateTimeMs="
    let result = ADB.run(
      ["-s", transport, "shell", "dumpsys notification --noredact | grep -E '\(filter)'"],
      timeout: 8)
    guard result.ok else { return nil }
    return parse(result.output)
  }

  nonisolated static func parse(_ output: String) -> [Item] {
    var items: [Item] = []
    var current: [String: String] = [:]
    func flush() {
      defer { current = [:] }
      guard let package = current["pkg"], let key = current["key"] else { return }
      let flags = current["flags"] ?? ""
      let importance = Int(current["importance"] ?? "") ?? 3
      // Ongoing (music, navigation, downloads), group summaries and silent ones stay on the phone.
      let noise = ["ONGOING_EVENT", "FOREGROUND_SERVICE", "GROUP_SUMMARY", "NO_CLEAR"]
      guard importance >= 3, !noise.contains(where: flags.contains),
        package != "android", package != "com.android.systemui"
      else { return }
      let title = current["title"]
      let text = current["text"]
      guard title != nil || text != nil else { return }
      items.append(
        Item(
          package: package, app: current["appLabel"] ?? package, title: title, text: text,
          key: key, alertsOnce: flags.contains("ONLY_ALERT_ONCE"),
          updated: current["updated"] ?? ""))
    }
    for line in output.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("NotificationRecord(") {
        flush()
        for field in trimmed.split(separator: " ") {
          for name in ["pkg", "importance", "key"] where field.hasPrefix("\(name)=") {
            current[name] = String(field.dropFirst(name.count + 1)).trimmingCharacters(
              in: CharacterSet(charactersIn: ":"))
          }
        }
      } else if trimmed.hasPrefix("flags=") {
        current["flags"] = String(trimmed.dropFirst(6))
      } else if trimmed.hasPrefix("mUpdateTimeMs=") {
        current["updated"] = String(trimmed.dropFirst(14))
      } else {
        for name in ["title", "text", "appLabel"] where trimmed.hasPrefix("android.\(name)=") {
          current[name] = value(trimmed.dropFirst(name.count + 9))
        }
      }
    }
    flush()
    return items
  }

  /// `String (text)` → text; `null` → nil.
  nonisolated private static func value(_ raw: Substring) -> String? {
    guard let open = raw.firstIndex(of: "("), raw.hasSuffix(")") else { return nil }
    let text = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
      .trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : text
  }
}
