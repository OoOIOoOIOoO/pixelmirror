import AppKit
import SwiftUI

struct PreferencesCard: View {
  @ObservedObject var updater: Updater
  @State private var language = AppLanguage.current

  @AppStorage(Telemetry.key) private var sharesUsageStatistics = true
  @AppStorage(PhoneNotifications.key) private var showsPhoneNotifications = true
  @ObservedObject private var notifications = PhoneNotifications.shared

  var body: some View {
    SettingsGroup {
      SettingsRow(
        "globe", tint: .indigo, title: String(localized: "Language"),
        subtitle: language == AppLanguage.atLaunch
          ? nil : String(localized: "Relaunch PixelMirror to switch languages.")
      ) {
        if language != AppLanguage.atLaunch {
          Button("Relaunch", action: AppLanguage.relaunch)
            .controlSize(.small)
        }
        Picker(
          "Language",
          selection: Binding(
            get: { language },
            set: {
              language = $0
              AppLanguage.choose($0)
            })
        ) {
          Text("System Language").tag("")
          ForEach(AppLanguage.available, id: \.self) { code in
            Text(verbatim: AppLanguage.name(of: code)).tag(code)
          }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
      }
      SettingsDivider()
      SettingsRow(
        "bell.badge.fill", tint: .red, title: String(localized: "Phone notifications"),
        subtitle: showsPhoneNotifications && notifications.denied
          ? String(localized: "Allow them in System Settings.") : nil
      ) {
        if showsPhoneNotifications, notifications.denied {
          Button(String(localized: "Open Settings")) {
            let id = Bundle.main.bundleIdentifier ?? ""
            if let url = URL(
              string:
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
            {
              NSWorkspace.shared.open(url)
            }
          }
          .controlSize(.small)
        }
        Toggle("Phone notifications", isOn: $showsPhoneNotifications)
          .toggleStyle(.switch)
          .labelsHidden()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) {
        _ in notifications.refreshAuthorization()
      }
      SettingsDivider()
      SettingsRow(
        "arrow.triangle.2.circlepath", tint: .green,
        title: String(localized: "Install updates automatically")
      ) {
        Toggle("Install updates automatically", isOn: $updater.installsAutomatically)
          .toggleStyle(.switch)
          .labelsHidden()
      }
      SettingsDivider()
      SettingsRow(
        "chart.bar.fill", tint: .blue,
        title: String(localized: "Share anonymous usage statistics"),
        subtitle: String(
          localized: "Counts active Macs once a day. Nothing from your screen is sent.")
      ) {
        Toggle("Share anonymous usage statistics", isOn: $sharesUsageStatistics)
          .toggleStyle(.switch)
          .labelsHidden()
      }
    }
  }
}

private enum AppLanguage {
  static let atLaunch = current

  static var current: String {
    let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
    return (domain?["AppleLanguages"] as? [String])?.first ?? ""
  }

  static let available = Set(Bundle.main.localizations).subtracting(["Base"]).sorted {
    name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending
  }

  static func name(of code: String) -> String {
    let locale = Locale(identifier: code)
    return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
  }

  static func choose(_ code: String) {
    if code.isEmpty {
      UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    } else {
      UserDefaults.standard.set([code], forKey: "AppleLanguages")
    }
  }

  static func relaunch() {
    let reopen = Process()
    reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
    reopen.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? reopen.run()
    NSApp.terminate(nil)
  }
}
