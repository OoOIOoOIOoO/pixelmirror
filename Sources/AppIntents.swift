import AppIntents
import Foundation

/// A phone app as Shortcuts and Spotlight see it.
struct PhoneAppEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Phone App"
  static let defaultQuery = PhoneAppQuery()

  var id: String
  var label: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(label)") }

  init(_ app: PhoneApp) {
    id = app.package
    label = app.label
  }
}

struct PhoneAppQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [PhoneAppEntity] {
    let all = await Self.all()
    return identifiers.compactMap { id in all.first { $0.id == id } }
  }

  /// Recently opened apps first, then the rest of the phone's apps.
  func suggestedEntities() async throws -> [PhoneAppEntity] {
    await Self.all()
  }

  func entities(matching string: String) async throws -> [PhoneAppEntity] {
    await Self.all().filter { $0.label.localizedCaseInsensitiveContains(string) }
  }

  @MainActor private static func all() -> [PhoneAppEntity] {
    let store = PhoneApps.shared
    var apps = store.recents
    for phone in DeviceHub.shared.known {
      let known = Set(apps.map(\.package))
      apps += store.apps(onPhoneID: phone.id).filter { !known.contains($0.package) }
    }
    return apps.map(PhoneAppEntity.init)
  }
}

struct OpenPhoneAppIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Phone App"
  static let description = IntentDescription("Opens an app from your phone in a window of its own.")
  static let openAppWhenRun = true

  @Parameter(title: "App")
  var app: PhoneAppEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    // Launched cold, the app needs a moment to find the phone.
    for _ in 0..<40 where MirrorManager.shared.currentPhone == nil {
      try await Task.sleep(for: .milliseconds(250))
    }
    guard let phone = MirrorManager.shared.currentPhone else {
      throw PhoneNotFound()
    }
    MirrorManager.shared.open(PhoneApp(package: app.id, label: app.label), on: phone)
    return .result()
  }

  struct PhoneNotFound: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "Your phone isn't connected." }
  }
}

struct PixelMirrorShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenPhoneAppIntent(),
      phrases: [
        "Open \(\.$app) in \(.applicationName)", "Open a phone app in \(.applicationName)",
      ],
      shortTitle: "Open Phone App", systemImageName: "iphone")
  }
}
