import AppKit
import SwiftUI

struct PreferencesCard: View {
  @ObservedObject var updater: Updater
  @State private var language = AppLanguage.current

  @AppStorage(Telemetry.key) private var sharesUsageStatistics = true
  @AppStorage(PhoneNotifications.key) private var showsPhoneNotifications = true
  @ObservedObject private var notifications = PhoneNotifications.shared
  @ObservedObject private var privacy = MirrorCapturePrivacy.shared

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
      MenuBarNotificationPreferences()
      SettingsDivider()
      SettingsRow(
        "eye.slash.fill", tint: .indigo, title: String(localized: "Private window"),
        subtitle: String(localized: "Protect the phone video from supported screen captures.")
      ) {
        Toggle("Private window", isOn: $privacy.enabled)
          .toggleStyle(.switch)
          .labelsHidden()
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

private struct MenuBarNotificationPreferences: View {
  @ObservedObject private var notifications = MenuBarNotifications.shared
  @ObservedObject private var hub = DeviceHub.shared
  @ObservedObject private var phoneApps = PhoneApps.shared
  @State private var expanded = false

  var body: some View {
    SettingsRow(
      "number", tint: .red, title: String(localized: "Menu bar notification count")
    ) {
      Toggle("Menu bar notification count", isOn: $notifications.enabled)
        .toggleStyle(.switch)
        .labelsHidden()
    }
    if notifications.enabled {
      DisclosureGroup("Notification apps", isExpanded: $expanded) {
        let apps = notifications.apps(from: hub.phones.flatMap { phoneApps.apps(on: $0) })
        if apps.isEmpty {
          Text("No phone apps available")
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 7) {
              ForEach(apps) { app in
                Toggle(
                  isOn: Binding(
                    get: { notifications.includes(app) },
                    set: { notifications.setApp(app, enabled: $0) })
                ) {
                  Text(verbatim: app.label)
                }
                .toggleStyle(.switch)
                .font(.system(size: 12))
              }
            }
            .padding(.vertical, 7)
            .padding(.trailing, 6)
          }
          .frame(height: min(180, CGFloat(apps.count) * 26 + 14))
        }
      }
      .controlSize(.small)
      .padding(.leading, SettingsMetrics.dividerInset)
      .padding(.trailing, SettingsMetrics.rowPaddingH)
      .padding(.bottom, 10)
      .onAppear(perform: refreshApps)
      .onChange(of: expanded) { _, _ in refreshApps() }
      .onChange(of: hub.phones) { _, _ in refreshApps() }
    }
  }

  private func refreshApps() {
    guard expanded else { return }
    for phone in hub.phones { phoneApps.refresh(phone) }
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
