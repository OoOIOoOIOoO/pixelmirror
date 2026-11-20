import AppKit
import SwiftUI

/// An app installed on the phone that can be opened in a Mac window of its own.
struct PhoneApp: Codable, Hashable, Identifiable {
  var package: String
  var label: String
  var id: String { package }
}

/// The phone's apps, listed by the scrcpy server and kept between launches, and the
/// ones opened lately.
@MainActor
final class PhoneApps: ObservableObject {
  static let shared = PhoneApps()

  @Published private(set) var apps: [String: [PhoneApp]] = [:]  // by phone id
  @Published private(set) var loading: Set<String> = []
  @Published private(set) var recents: [PhoneApp] = []

  private init() {
    if let data = UserDefaults.standard.data(forKey: "recentApps"),
      let list = try? JSONDecoder().decode([PhoneApp].self, from: data)
    {
      recents = list
    }
  }

  func apps(on phone: Phone) -> [PhoneApp] { apps(onPhoneID: phone.id) }

  func apps(onPhoneID id: String) -> [PhoneApp] {
    if let list = apps[id] { return list }
    guard let data = UserDefaults.standard.data(forKey: "apps-\(id)"),
      let list = try? JSONDecoder().decode([PhoneApp].self, from: data)
    else { return [] }
    return list
  }

  /// Lists the apps again; the last list shows meanwhile.
  func refresh(_ phone: Phone) {
    guard !loading.contains(phone.id) else { return }
    loading.insert(phone.id)
    let transport = phone.transport
    DispatchQueue.global().async {
      let list = Self.list(transport)
      DispatchQueue.main.async {
        self.loading.remove(phone.id)
        guard !list.isEmpty else { return }
        self.apps[phone.id] = list
        if let data = try? JSONEncoder().encode(list) {
          UserDefaults.standard.set(data, forKey: "apps-\(phone.id)")
        }
        PixelMirrorShortcuts.updateAppShortcutParameters()
      }
    }
  }

  func opened(_ app: PhoneApp) {
    recents.removeAll { $0.package == app.package }
    recents.insert(app, at: 0)
    recents = Array(recents.prefix(8))
    if let data = try? JSONEncoder().encode(recents) {
      UserDefaults.standard.set(data, forKey: "recentApps")
    }
    PixelMirrorShortcuts.updateAppShortcutParameters()
  }

  /// `list_apps` prints ` * Label   package` for system apps and ` - …` for the rest.
  nonisolated private static func list(_ transport: String) -> [PhoneApp] {
    let remote = "/data/local/tmp/pixelmirror-server.jar"
    guard ADB.run(["-s", transport, "push", ADB.server.path, remote], timeout: 40).ok else {
      return []
    }
    let command =
      "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server \(ADB.serverVersion) "
      + "list_apps=true log_level=info"
    let output = ADB.run(["-s", transport, "shell", command], timeout: 40).output
    var seen = Set<String>()
    return output.split(separator: "\n").compactMap { line -> PhoneApp? in
      guard line.hasPrefix(" * ") || line.hasPrefix(" - ") else { return nil }
      let body = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
      guard let space = body.lastIndex(where: \.isWhitespace) else {
        return body.isEmpty ? nil : PhoneApp(package: body, label: body)
      }
      let package = String(body[body.index(after: space)...])
      let label = body[..<space].trimmingCharacters(in: .whitespaces)
      guard seen.insert(package).inserted else { return nil }
      return PhoneApp(package: package, label: label.isEmpty ? package : label)
    }
    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }
}

// MARK: - Open App…

/// A small window to find an app on the phone and open it in a window of its own.
@MainActor
final class AppPicker {
  static let shared = AppPicker()
  private var window: NSWindow?

  func show(for phone: Phone) {
    PhoneApps.shared.refresh(phone)
    let view = AppPickerView(phone: phone) { [weak self] app in
      MirrorManager.shared.open(app, on: phone)
      self?.window?.close()
    }
    let window =
      self.window
      ?? NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
        styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = String(localized: "Open App")
    window.subtitle = phone.name
    window.contentView = NSHostingView(rootView: view)
    window.contentMinSize = NSSize(width: 300, height: 320)
    if self.window == nil { window.center() }
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct AppPickerView: View {
  let phone: Phone
  let open: (PhoneApp) -> Void
  @ObservedObject private var store = PhoneApps.shared
  @State private var search = ""
  @State private var selection: String?
  @FocusState private var searching: Bool

  var body: some View {
    VStack(spacing: 0) {
      TextField("Search", text: $search)
        .textFieldStyle(.roundedBorder)
        .focused($searching)
        .onSubmit { if let first = matches.first { open(first) } }
        .padding(10)
      Divider()
      if all.isEmpty {
        VStack(spacing: 10) {
          if store.loading.contains(phone.id) {
            ProgressView().controlSize(.small)
            Text("Loading apps…")
          } else {
            Text("No apps found")
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        list
      }
    }
    .frame(minWidth: 300, minHeight: 320)
    .onAppear { DispatchQueue.main.async { searching = true } }
  }

  private var list: some View {
    List(selection: $selection) {
      if search.isEmpty, !recents.isEmpty {
        Section("Recent") {
          ForEach(recents) { row($0) }
        }
        Section("All Apps") {
          ForEach(all) { row($0) }
        }
      } else {
        ForEach(matches) { row($0) }
      }
    }
    .listStyle(.inset)
    .contextMenu(forSelectionType: String.self) { _ in
    } primaryAction: { ids in
      if let id = ids.first, let app = all.first(where: { $0.package == id }) { open(app) }
    }
  }

  private func row(_ app: PhoneApp) -> some View {
    HStack(spacing: 9) {
      AppMonogram(app: app, size: 22)
      Text(verbatim: app.label)
        .lineLimit(1)
    }
    .tag(app.package)
    .padding(.vertical, 1)
  }

  private var all: [PhoneApp] { store.apps(on: phone) }

  private var recents: [PhoneApp] {
    let installed = Set(all.map(\.package))
    return store.recents.filter { installed.contains($0.package) }
  }

  private var matches: [PhoneApp] {
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return all }
    return all.filter {
      $0.label.localizedCaseInsensitiveContains(query) || $0.package.contains(query.lowercased())
    }
  }
}

/// The app's first letter on a color of its own, since the phone does not share its icons.
struct AppMonogram: View {
  let app: PhoneApp
  let size: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
      .fill(color.gradient)
      .frame(width: size, height: size)
      .overlay(
        Text(verbatim: String(app.label.prefix(1)).uppercased())
          .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
          .foregroundStyle(.white)
      )
  }

  private var color: Color {
    let hash = app.package.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.8)
  }
}
