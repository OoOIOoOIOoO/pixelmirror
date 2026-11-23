import Combine
import Foundation

/// A local count derived from phone notifications, independent of macOS notification delivery.
@MainActor
final class MenuBarNotifications: ObservableObject {
  static let shared = MenuBarNotifications()

  @Published var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: "menuBarNotificationCountEnabled")
      if !enabled {
        snapshots.removeAll()
        count = 0
      }
    }
  }
  @Published private(set) var selectedApps: [PhoneApp]
  @Published private(set) var count = 0

  private struct Snapshot {
    var current = Set<String>()
    var pending: [String: String] = [:]
  }

  private let defaults: UserDefaults
  private var snapshots: [String: Snapshot] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.bool(forKey: "menuBarNotificationCountEnabled")
    let stored = defaults.data(forKey: "menuBarNotificationApps")
    selectedApps = stored.flatMap { try? JSONDecoder().decode([PhoneApp].self, from: $0) } ?? []
  }

  func apps(from installed: [PhoneApp]) -> [PhoneApp] {
    var packages = Set(selectedApps.map(\.package))
    let available = installed.sorted {
      let order = $0.label.localizedStandardCompare($1.label)
      return order == .orderedSame ? $0.package < $1.package : order == .orderedAscending
    }
    return selectedApps + available.filter { packages.insert($0.package).inserted }
  }

  func includes(_ app: PhoneApp) -> Bool {
    selectedApps.contains { $0.package == app.package }
  }

  func setApp(_ app: PhoneApp, enabled: Bool) {
    selectedApps.removeAll { $0.package == app.package }
    if enabled {
      selectedApps.insert(app, at: 0)
    } else {
      for phone in Array(snapshots.keys) {
        let remaining = snapshots[phone]?.pending.filter { $0.value != app.package } ?? [:]
        snapshots[phone]?.pending = remaining
      }
    }
    defaults.set(try? JSONEncoder().encode(selectedApps), forKey: "menuBarNotificationApps")
    updateCount()
  }

  func retainPhones(_ ids: Set<String>) {
    snapshots = snapshots.filter { ids.contains($0.key) }
    updateCount()
  }

  func received(_ items: [PhoneNotifications.Item], phoneID: String) {
    guard enabled else { return }
    let selected = Set(selectedApps.map(\.package))
    let current = Set(items.map(\.key))
    let previous = snapshots[phoneID]
    var snapshot = Snapshot(
      current: current, pending: previous?.pending.filter { current.contains($0.key) } ?? [:])
    if let previous {
      for item in items
      where !previous.current.contains(item.key) && selected.contains(item.package) {
        snapshot.pending[item.key] = item.package
      }
    }
    snapshots[phoneID] = snapshot
    updateCount()
  }

  func clear() {
    for phone in Array(snapshots.keys) {
      snapshots[phone]?.pending.removeAll()
    }
    count = 0
  }

  private func updateCount() {
    let total = snapshots.values.reduce(0) { $0 + $1.pending.count }
    if total != count { count = total }
  }
}
