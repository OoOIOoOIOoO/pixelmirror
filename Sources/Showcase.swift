import AppKit
import SwiftUI

struct AboutView: View {
  private static let icon: CGFloat = 240

  var body: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
        .resizable()
        .interpolation(.high)
        .frame(width: Self.icon * 1024 / 980, height: Self.icon * 1024 / 980)
        .frame(width: Self.icon, height: Self.icon)
        .clipShape(RoundedRectangle(cornerRadius: Self.icon * 262 / 980, style: .circular))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
        .padding(.top, 40)
        .padding(.bottom, 6)
        .accessibilityHidden(true)
      Text(verbatim: AppName.display)
        .font(.system(size: 24, weight: .semibold))
        .padding(.top, 8)
      Text("Your Android phone, live on your Mac.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 36)
        .padding(.top, 6)
      HStack(spacing: 6) {
        Text("Version \(versionLabel)")
        if let project = URL(string: "https://github.com/ReffWu/pixelmirror") {
          Text(verbatim: "·")
          Link(destination: project) { Text(verbatim: "GitHub") }
            .buttonStyle(.plain)
        }
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .padding(.top, 20)
      Text(verbatim: "© 2026 Reff Wu")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.top, 4)
        .padding(.bottom, 28)
    }
    .frame(width: 360)
    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    .background(AboutWindowChrome())
  }

  private var versionLabel: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? ""
    guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else { return version }
    return "\(version) (\(build))"
  }
}

private struct AboutWindowChrome: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      view.window?.styleMask.remove([.miniaturizable, .resizable])
    }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
final class MoreApps: ObservableObject {
  static let shared = MoreApps()

  struct Entry: Decodable, Identifiable, Equatable {
    let id: String
    let bundleID: String
    let name: String
    let icon: URL
    let page: URL
    let tagline: [String: String]

    var localizedTagline: String {
      let language = Bundle.main.preferredLocalizations.first ?? "en"
      return tagline[language] ?? tagline["en"] ?? ""
    }
  }

  private struct Catalog: Decodable {
    let apps: [Entry]
  }

  private static let catalogURL = URL(
    string: "https://reffwu.github.io/apps/catalog.json")
  private static let freshFor: TimeInterval = 24 * 60 * 60

  @Published private(set) var entries: [Entry] = []
  @Published private(set) var icons: [String: NSImage] = [:]

  private var isLoading = false
  private let directory: URL

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    directory =
      caches
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.reffwu.pixelmirror")
      .appendingPathComponent("MoreApps")
    showCached()
  }

  private var catalogFile: URL { directory.appendingPathComponent("catalog.json") }

  private func iconFile(for entry: Entry) -> URL {
    directory.appendingPathComponent("\(entry.id).png")
  }

  func refreshIfStale() {
    guard !isLoading, let url = Self.catalogURL else { return }
    let modified = (try? catalogFile.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    if let modified, Date().timeIntervalSince(modified) < Self.freshFor { return }

    isLoading = true
    Task {
      defer { isLoading = false }
      guard let (data, response) = try? await URLSession.shared.data(from: url),
        (response as? HTTPURLResponse)?.statusCode == 200,
        let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
      else { return }
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? data.write(to: catalogFile)
      for entry in catalog.apps where entry.bundleID != Bundle.main.bundleIdentifier {
        if let (icon, _) = try? await URLSession.shared.data(from: entry.icon),
          NSImage(data: icon) != nil
        {
          try? icon.write(to: iconFile(for: entry))
        }
      }
      showCached()
    }
  }

  private func showCached() {
    guard let data = try? Data(contentsOf: catalogFile),
      let catalog = try? JSONDecoder().decode(Catalog.self, from: data)
    else { return }
    let others = catalog.apps.filter { $0.bundleID != Bundle.main.bundleIdentifier }
    entries = others
    icons = Dictionary(
      uniqueKeysWithValues: others.compactMap { entry in
        NSImage(contentsOf: iconFile(for: entry)).map { (entry.id, $0) }
      })
  }
}

struct MoreAppsCard: View {
  @ObservedObject private var store = MoreApps.shared

  private static let icon: CGFloat = 40

  var body: some View {
    Group {
      if !store.entries.isEmpty {
        SettingsGroup(title: String(localized: "More from Reff Wu")) {
          ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
            if index > 0 { SettingsDivider(inset: 65) }
            row(entry)
          }
        }
      }
    }
  }

  private func row(_ entry: MoreApps.Entry) -> some View {
    let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
    return HStack(spacing: 11) {
      Group {
        if let icon = store.icons[entry.id] {
          Image(nsImage: icon).resizable().interpolation(.high)
        } else {
          Color.primary.opacity(0.08)
        }
      }
      .frame(width: Self.icon * 1024 / 980, height: Self.icon * 1024 / 980)
      .frame(width: Self.icon, height: Self.icon)
      .clipShape(RoundedRectangle(cornerRadius: Self.icon * 262 / 980, style: .circular))
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: entry.name).font(.system(size: 13))
        Text(verbatim: entry.localizedTagline)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 10)
      Button(installed == nil ? String(localized: "Get") : String(localized: "Open")) {
        if let installed {
          NSWorkspace.shared.openApplication(
            at: installed, configuration: NSWorkspace.OpenConfiguration())
        } else {
          NSWorkspace.shared.open(entry.page)
        }
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }
}
