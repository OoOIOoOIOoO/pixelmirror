import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files dropped on a phone window

/// Sends files to the phone's Download folder and tells its media scanner, so
/// photos and videos turn up in the gallery at once.
@MainActor
final class FileSender: ObservableObject {
  enum State: Equatable {
    case idle
    case sending(count: Int, progress: Double)
    case sent(count: Int)
    case failed(name: String)
    case note(symbol: String, text: String)
  }

  @Published private(set) var state = State.idle
  private var hideWork: DispatchWorkItem?

  /// A short message in the same place, such as a saved screenshot.
  func note(_ symbol: String, _ text: String) {
    guard !isBusy else { return }
    hideWork?.cancel()
    state = .note(symbol: symbol, text: text)
    let work = DispatchWorkItem { [weak self] in self?.state = .idle }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
  }

  var isBusy: Bool {
    if case .sending = state { return true }
    return false
  }

  /// `scan` reaches the phone's media scanner through the mirror session.
  func send(_ urls: [URL], transport: String, scan: @escaping (String) -> Void) {
    let files = urls.filter {
      (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
    guard !files.isEmpty, !isBusy else { return }
    hideWork?.cancel()
    state = .sending(count: files.count, progress: 0)
    DispatchQueue.global().async {
      let failed = Self.push(files, transport: transport, scan: scan) { progress in
        DispatchQueue.main.async { self.state = .sending(count: files.count, progress: progress) }
      }
      DispatchQueue.main.async {
        self.state = failed.map { .failed(name: $0) } ?? .sent(count: files.count)
        let work = DispatchWorkItem { [weak self] in self?.state = .idle }
        self.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
      }
    }
  }

  /// Returns the name of the first file that could not be sent.
  nonisolated private static func push(
    _ files: [URL], transport: String, scan: @escaping (String) -> Void,
    progress: @escaping (Double) -> Void
  ) -> String? {
    let folder = "/sdcard/Download"
    var taken = Set(ADB.shell(transport, "ls -1 \(folder)").split(separator: "\n").map(String.init))
    let sizes = files.map {
      Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    let total = max(sizes.reduce(0, +), 1)
    var done: Int64 = 0
    for (file, size) in zip(files, sizes) {
      let name = unique(file.lastPathComponent, in: taken)
      taken.insert(name)
      let remote = "\(folder)/\(name)"
      let process = ADB.spawn(["-s", transport, "push", file.path, remote])
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return file.lastPathComponent }
      // adb only reports progress to a terminal, so watch the file grow on the phone.
      while process.isRunning {
        Thread.sleep(forTimeInterval: 0.5)
        let sent = Int64(ADB.shell(transport, "stat -c %s \(quoted(remote))", timeout: 3)) ?? 0
        progress(Double(done + min(sent, size)) / Double(total))
      }
      guard process.terminationStatus == 0 else { return file.lastPathComponent }
      done += size
      progress(Double(done) / Double(total))
      scan(remote)
    }
    return nil
  }

  /// "photo.jpg", then "photo (1).jpg", as the phone's own Files app names copies.
  nonisolated private static func unique(_ name: String, in taken: Set<String>) -> String {
    guard taken.contains(name) else { return name }
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    for n in 1... {
      let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
      if !taken.contains(candidate) { return candidate }
    }
    return name
  }

  nonisolated static func quoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

/// The small status shown at the bottom of a phone window while files go across.
struct TransferHUD: View {
  @ObservedObject var sender: FileSender
  var dropping: Bool

  var body: some View {
    Group {
      if dropping {
        label("arrow.down.doc.fill", String(localized: "Drop to send to Downloads"))
      } else {
        switch sender.state {
        case .idle:
          EmptyView()
        case .sending(let count, let progress):
          VStack(alignment: .leading, spacing: 6) {
            Text("Sending…")
              .font(.system(size: 12, weight: .medium))
            ProgressView(value: progress).controlSize(.small)
          }
          .frame(width: 200)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .sent:
          label("checkmark.circle.fill", String(localized: "Saved to Downloads"), tint: .green)
        case .note(let symbol, let text):
          label(symbol, text)
        case .failed(let name):
          label(
            "exclamationmark.circle.fill", String(localized: "Couldn't send \(name)"),
            tint: .orange)
        }
      }
    }
    .environment(\.colorScheme, .dark)
    .animation(.smooth(duration: 0.2), value: sender.state)
  }

  private func label(_ symbol: String, _ text: String, tint: Color = .accentColor) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol).foregroundStyle(tint)
      Text(verbatim: text).lineLimit(1)
    }
    .font(.system(size: 12, weight: .medium))
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(.regularMaterial, in: Capsule())
  }
}

// MARK: - Recent Photos

/// One photo or video in the phone's camera roll.
struct PhoneMedia: Identifiable, Hashable {
  var id: String  // MediaStore id
  var path: String
  var isVideo: Bool
  var name: String { (path as NSString).lastPathComponent }
}

/// The newest camera photos and videos, with thumbnails the phone already keeps.
@MainActor
final class RecentPhotos: ObservableObject {
  @Published private(set) var items: [PhoneMedia] = []
  @Published private(set) var thumbnails: [String: NSImage] = [:]
  @Published private(set) var loading = false
  let phone: Phone
  private var requested: Set<String> = []
  private let thumbnailQueue = DispatchQueue(
    label: "com.reffwu.pixelmirror.thumbnails", attributes: .concurrent)
  private let slots = DispatchSemaphore(value: 3)

  init(phone: Phone) { self.phone = phone }

  func refresh() {
    guard !loading else { return }
    loading = true
    let transport = phone.transport
    DispatchQueue.global().async {
      let list = Self.query(transport)
      DispatchQueue.main.async {
        self.loading = false
        self.items = list
      }
    }
  }

  /// Fetched only when the tile shows, a few at a time.
  func loadThumbnail(_ item: PhoneMedia) {
    guard requested.insert(item.id).inserted else { return }
    let uri =
      "content://media/external/\(item.isVideo ? "video" : "images")/media/\(item.id)/thumbnail"
    let transport = phone.transport
    let slots = slots
    thumbnailQueue.async {
      slots.wait()
      defer { slots.signal() }
      let data = ADB.data(["-s", transport, "exec-out", "content read --uri \(uri)"])
      guard let data, let image = NSImage(data: data) else { return }
      DispatchQueue.main.async { self.thumbnails[item.id] = image }
    }
  }

  nonisolated private static func query(_ transport: String) -> [PhoneMedia] {
    let output = ADB.shell(
      transport,
      "content query --uri content://media/external/file --projection _id:_data:media_type "
        + "--where \"media_type IN (1,3) AND relative_path LIKE 'DCIM/%'\" "
        + "--sort 'date_added DESC'", timeout: 15)
    return output.split(separator: "\n").prefix(60).compactMap { line in
      guard line.hasPrefix("Row:"),
        let id = field("_id", in: line), let path = field("_data", in: line),
        let type = field("media_type", in: line)
      else { return nil }
      return PhoneMedia(id: id, path: path, isVideo: type == "3")
    }
  }

  /// `key=value` from a `content query` row; values run to the next `, key=`.
  nonisolated private static func field(_ key: String, in line: Substring) -> String? {
    guard let start = line.range(of: " \(key)=") else { return nil }
    let rest = line[start.upperBound...]
    let end =
      rest.range(of: #", [a-z_]+="#, options: .regularExpression)?.lowerBound ?? rest.endIndex
    return String(rest[..<end])
  }
}

@MainActor
final class RecentPhotosPanel {
  static let shared = RecentPhotosPanel()
  private var window: NSPanel?
  private var store: RecentPhotos?

  func show(for phone: Phone) {
    if store?.phone.id != phone.id { store = RecentPhotos(phone: phone) }
    guard let store else { return }
    store.refresh()
    let panel =
      window
      ?? NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 372, height: 480),
        styleMask: [.titled, .closable, .resizable, .utilityWindow],
        backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.title = String(localized: "Recent Photos")
    panel.subtitle = phone.name
    panel.contentView = NSHostingView(rootView: RecentPhotosView(store: store))
    panel.contentMinSize = NSSize(width: 250, height: 260)
    if window == nil {
      panel.setFrameAutosaveName("RecentPhotos")
      if !panel.setFrameUsingName("RecentPhotos") { panel.center() }
    }
    window = panel
    panel.makeKeyAndOrderFront(nil)
  }
}

private struct RecentPhotosView: View {
  @ObservedObject var store: RecentPhotos

  var body: some View {
    Group {
      if store.items.isEmpty {
        VStack(spacing: 10) {
          if store.loading {
            ProgressView().controlSize(.small)
          } else {
            Text("No photos yet")
          }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
            ForEach(store.items) { item in
              PhotoTile(
                item: item, image: store.thumbnails[item.id], transport: store.phone.transport
              )
              .aspectRatio(1, contentMode: .fill)
              .onAppear { store.loadThumbnail(item) }
            }
          }
          .padding(4)
        }
      }
    }
    .frame(minWidth: 250, minHeight: 260)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      Text("Drag to Finder to save.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.bar)
    }
  }
}

private struct PhotoTile: View {
  let item: PhoneMedia
  let image: NSImage?
  let transport: String

  var body: some View {
    Color(nsColor: .quaternaryLabelColor)
      .overlay {
        if let image {
          Image(nsImage: image).resizable().scaledToFill()
        }
      }
      .overlay(alignment: .bottomLeading) {
        if item.isVideo {
          Image(systemName: "video.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(6)
        }
      }
      .overlay { PromiseDragSource(item: item, image: image, transport: transport) }
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
      .help(item.name)
  }
}

/// Drags the full photo or video out of the phone: Finder gets a promise and
/// the file is pulled once it is dropped.
private struct PromiseDragSource: NSViewRepresentable {
  let item: PhoneMedia
  let image: NSImage?
  let transport: String

  func makeNSView(context: Context) -> DragView { DragView() }

  func updateNSView(_ view: DragView, context: Context) {
    view.item = item
    view.image = image
    view.transport = transport
  }

  final class DragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var item: PhoneMedia?
    var image: NSImage?
    var transport = ""
    private let queue = OperationQueue()

    override func mouseDragged(with event: NSEvent) {
      guard let item else { return }
      let type = (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
      let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
      let dragItem = NSDraggingItem(pasteboardWriter: provider)
      dragItem.setDraggingFrame(bounds, contents: image ?? NSImage(size: bounds.size))
      beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String)
      -> String
    { item?.name ?? "Photo" }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(
      _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
      completionHandler: @escaping (Error?) -> Void
    ) {
      guard let item else { return completionHandler(CocoaError(.fileNoSuchFile)) }
      let result = ADB.run(["-s", transport, "pull", item.path, url.path], timeout: 600)
      completionHandler(result.ok ? nil : CocoaError(.fileReadUnknown))
    }
  }
}
