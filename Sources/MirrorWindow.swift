import AVFoundation
import AppKit
import SwiftUI

/// Opens one window per phone, keeps it going across Wi-Fi drops and reboots,
/// and reopens it by itself when the phone comes back.
@MainActor
final class MirrorManager: ObservableObject {
  static let shared = MirrorManager()

  @Published private(set) var mirroring: Set<String> = []
  private var controllers: [String: MirrorWindowController] = [:]

  /// Phones whose window someone closed: they are not reopened until they disconnect.
  private var dismissed: Set<String> = []

  func phoneBecameReady(_ phone: Phone) {
    if let controller = controllers[phone.id] {
      controller.resume(with: phone)
    } else if !dismissed.contains(phone.id) {
      open(phone)
    }
  }

  func phonesChanged(_ phones: [Phone]) {
    let present = Set(phones.map(\.id))
    dismissed = dismissed.intersection(present)
    for (id, controller) in controllers where !present.contains(id) {
      controller.phoneWentAway()
    }
  }

  func open(_ phone: Phone) {
    dismissed.remove(phone.id)
    if let controller = controllers[phone.id] {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    let controller = MirrorWindowController(phone: phone)
    controller.onClose = { [weak self] in
      self?.controllers[phone.id] = nil
      self?.mirroring.remove(phone.id)
      self?.dismissed.insert(phone.id)
    }
    controllers[phone.id] = controller
    mirroring.insert(phone.id)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  var keyController: MirrorWindowController? {
    controllers.values.first { $0.window?.isKeyWindow == true }
      ?? controllers.values.first { $0.window?.isMainWindow == true }
  }
}

@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate, MirrorSessionDelegate {
  private(set) var phone: Phone
  private let mirrorView = MirrorView()
  private let overlay = NSHostingView(rootView: MirrorOverlay(text: "", busy: true))
  private var session: MirrorSession?
  private var videoSize = CGSize.zero
  private var retries = 0
  private var phonePresent = true
  var onClose: (() -> Void)?

  @AppStorage("phoneScreenOff") private var phoneScreenOff = true

  init(phone: Phone) {
    self.phone = phone
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.titleVisibility = .visible
    window.backgroundColor = .black
    window.appearance = NSAppearance(named: .darkAqua)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("Mirror-\(phone.id)")
    super.init(window: window)
    window.delegate = self

    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.black.cgColor
    mirrorView.translatesAutoresizingMaskIntoConstraints = false
    overlay.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(mirrorView)
    container.addSubview(overlay)
    NSLayoutConstraint.activate([
      mirrorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      mirrorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      mirrorView.topAnchor.constraint(equalTo: container.topAnchor),
      mirrorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    window.contentView = container
    window.toolbar = makeToolbar()
    window.toolbarStyle = .unifiedCompact
    updateTitle()
    if !window.setFrameUsingName("Mirror-\(phone.id)") { window.center() }
    startSession()
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: - Session

  private func startSession() {
    session?.delegate = nil
    session?.stop()
    showOverlay(String(localized: "Connecting to \(phone.name)…"), busy: true)
    let session = MirrorSession(
      transport: phone.transport, isUSB: phone.isUSB, renderer: mirrorView.displayLayer)
    session.delegate = self
    mirrorView.control = session.input
    self.session = session
    session.start()
  }

  func resume(with phone: Phone) {
    self.phone = phone
    phonePresent = true
    updateTitle()
    if session == nil {
      retries = 0
      startSession()
    }
  }

  func phoneWentAway() {
    phonePresent = false
    showOverlay(String(localized: "Waiting for \(phone.name)…"), busy: true)
  }

  func sessionDidStart(_ session: MirrorSession, deviceName: String) {
    guard session === self.session else { return }
    retries = 0
    if phoneScreenOff { session.input.setScreenPower(on: false) }
  }

  func session(_ session: MirrorSession, videoSizeChanged size: CGSize) {
    guard session === self.session, size.width > 0, size.height > 0 else { return }
    hideOverlay()
    let rotated =
      videoSize != .zero && (videoSize.width > videoSize.height) != (size.width > size.height)
    let first = videoSize == .zero
    videoSize = size
    mirrorView.videoSize = size
    fit(to: size, resize: first || rotated)
  }

  func sessionDidEnd(_ session: MirrorSession, error: String?) {
    guard session === self.session else { return }
    self.session = nil
    mirrorView.control = nil
    guard window?.isVisible == true else { return }
    if phonePresent, retries < 3 {
      retries += 1
      showOverlay(String(localized: "Reconnecting…"), busy: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
        guard let self, self.session == nil, self.phonePresent else { return }
        self.startSession()
      }
    } else {
      showOverlay(String(localized: "Waiting for \(phone.name)…"), busy: true)
    }
  }

  // MARK: - Window

  private func updateTitle() {
    window?.title = phone.name
    window?.subtitle = phone.isUSB ? String(localized: "USB") : String(localized: "Wi-Fi")
  }

  private func fit(to size: CGSize, resize: Bool) {
    guard let window, let screen = window.screen ?? NSScreen.main else { return }
    window.contentAspectRatio = size
    guard resize, !window.styleMask.contains(.fullScreen) else { return }
    let visible = screen.visibleFrame
    var height = min(visible.height * 0.86, size.height / (screen.backingScaleFactor))
    if size.width > size.height { height = min(visible.height * 0.7, height) }
    var width = height * size.width / size.height
    if width > visible.width * 0.9 {
      width = visible.width * 0.9
      height = width * size.height / size.width
    }
    let content = NSRect(x: 0, y: 0, width: width, height: height)
    var frame = window.frameRect(forContentRect: content)
    let old = window.frame
    frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.maxY - frame.height)
    frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
    window.setFrame(frame, display: true, animate: !resize || videoSize != size)
  }

  private func showOverlay(_ text: String, busy: Bool) {
    overlay.rootView = MirrorOverlay(text: text, busy: busy)
    overlay.isHidden = false
  }

  private func hideOverlay() {
    overlay.isHidden = true
  }

  func windowWillClose(_ notification: Notification) {
    session?.delegate = nil
    session?.stop()
    session = nil
    onClose?()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    window?.makeFirstResponder(mirrorView)
  }

  // MARK: - Commands

  func back() { session?.input.backOrScreenOn() }
  func home() { session?.input.tap(ControlChannel.Key.home) }
  func recents() { session?.input.tap(ControlChannel.Key.appSwitch) }
  func volumeUp() { session?.input.tap(ControlChannel.Key.volumeUp) }
  func volumeDown() { session?.input.tap(ControlChannel.Key.volumeDown) }
  func rotate() { session?.input.rotate() }
  func notifications() { session?.input.expandNotifications() }

  func togglePhoneScreen() {
    phoneScreenOff.toggle()
    session?.input.setScreenPower(on: !phoneScreenOff)
    window?.toolbar?.items.first { $0.itemIdentifier == .screen }.map(styleScreenItem)
  }

  private func styleScreenItem(_ item: NSToolbarItem) {
    item.image = NSImage(
      systemSymbolName: phoneScreenOff ? "iphone.slash" : "iphone", accessibilityDescription: nil)
    item.label = String(localized: "Phone Screen")
    item.toolTip =
      phoneScreenOff
      ? String(localized: "Turn the phone's screen on")
      : String(localized: "Turn the phone's screen off")
  }
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
  static let back = Self("back")
  static let home = Self("home")
  static let recents = Self("recents")
  static let rotate = Self("rotate")
  static let screen = Self("screen")
}

extension MirrorWindowController: NSToolbarDelegate {
  fileprivate func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "mirror")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    return toolbar
  }

  nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
  {
    [.flexibleSpace, .back, .home, .recents, .rotate, .screen]
  }

  nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
  {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  nonisolated func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    MainActor.assumeIsolated {
      let item = NSToolbarItem(itemIdentifier: id)
      item.isBordered = true
      item.target = self
      switch id {
      case .back:
        item.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        item.label = String(localized: "Back")
        item.action = #selector(backAction)
      case .home:
        item.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        item.label = String(localized: "Home")
        item.action = #selector(homeAction)
      case .recents:
        item.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil)
        item.label = String(localized: "Recent Apps")
        item.action = #selector(recentsAction)
      case .rotate:
        item.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: nil)
        item.label = String(localized: "Rotate")
        item.action = #selector(rotateAction)
      case .screen:
        styleScreenItem(item)
        item.action = #selector(screenAction)
      default:
        return nil
      }
      item.toolTip = item.toolTip ?? item.label
      return item
    }
  }

  @objc private func backAction() { back() }
  @objc private func homeAction() { home() }
  @objc private func recentsAction() { recents() }
  @objc private func rotateAction() { rotate() }
  @objc private func screenAction() { togglePhoneScreen() }
}

private struct MirrorOverlay: View {
  var text: String
  var busy: Bool

  var body: some View {
    VStack(spacing: 12) {
      if busy { ProgressView().controlSize(.small) }
      Text(verbatim: text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .environment(\.colorScheme, .dark)
  }
}

// MARK: - The view that shows the phone and takes input

final class MirrorView: NSView, NSTextInputClient {
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  var control: ControlChannel?
  var videoSize = CGSize.zero

  private var marked = NSMutableAttributedString()
  private var scrollFinger: CGPoint?
  private var pinch: (center: CGPoint, distance: CGFloat)?
  private var heldKeys: [UInt16: Int32] = [:]

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
  }

  required init?(coder: NSCoder) { fatalError() }

  override func makeBackingLayer() -> CALayer {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = NSColor.black.cgColor
    return layer
  }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  // MARK: Coordinates

  private var videoRect: CGRect {
    guard videoSize.width > 0, bounds.width > 0 else { return bounds }
    let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
    let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
      width: size.width, height: size.height)
  }

  private func phonePoint(_ event: NSEvent) -> CGPoint {
    phonePoint(convert(event.locationInWindow, from: nil))
  }

  private func phonePoint(_ point: CGPoint) -> CGPoint {
    let rect = videoRect
    let x = (point.x - rect.minX) / rect.width * videoSize.width
    let y = (point.y - rect.minY) / rect.height * videoSize.height
    return CGPoint(
      x: min(max(x, 0), videoSize.width - 1), y: min(max(y, 0), videoSize.height - 1))
  }

  /// View points to phone pixels.
  private var pixelsPerPoint: CGFloat {
    let rect = videoRect
    return rect.width > 0 ? videoSize.width / rect.width : 1
  }

  // MARK: Mouse: the pointer is a finger

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    control?.touch(.down, pointer: ControlChannel.Pointer.mouse, at: phonePoint(event))
  }

  override func mouseDragged(with event: NSEvent) {
    control?.touch(.move, pointer: ControlChannel.Pointer.mouse, at: phonePoint(event))
  }

  override func mouseUp(with event: NSEvent) {
    control?.touch(.up, pointer: ControlChannel.Pointer.mouse, at: phonePoint(event))
  }

  override func rightMouseDown(with event: NSEvent) {
    control?.backOrScreenOn()
  }

  override func otherMouseDown(with event: NSEvent) {
    control?.tap(ControlChannel.Key.home)
  }

  // MARK: Trackpad: two-finger scrolling drags a finger, so the phone flings natively

  override func scrollWheel(with event: NSEvent) {
    guard let control else { return }
    guard event.hasPreciseScrollingDeltas, event.phase != [] || event.momentumPhase != [] else {
      // A mouse wheel: real scroll steps.
      control.scroll(
        at: phonePoint(event), horizontal: -event.scrollingDeltaX, vertical: event.scrollingDeltaY)
      return
    }
    if event.momentumPhase != [] { return }  // the phone does its own momentum
    let scale = pixelsPerPoint
    switch event.phase {
    case .began, .mayBegin:
      let start = phonePoint(event)
      scrollFinger = start
      control.touch(.down, pointer: ControlChannel.Pointer.scroll, at: start)
    case .changed:
      guard var finger = scrollFinger else { return }
      finger.x += event.scrollingDeltaX * scale
      finger.y += event.scrollingDeltaY * scale
      finger.x = min(max(finger.x, 0), videoSize.width - 1)
      finger.y = min(max(finger.y, 0), videoSize.height - 1)
      scrollFinger = finger
      control.touch(.move, pointer: ControlChannel.Pointer.scroll, at: finger)
    case .ended, .cancelled:
      if let finger = scrollFinger {
        control.touch(.up, pointer: ControlChannel.Pointer.scroll, at: finger)
      }
      scrollFinger = nil
    default:
      break
    }
  }

  // MARK: Trackpad: pinch is two fingers

  override func magnify(with event: NSEvent) {
    guard let control else { return }
    switch event.phase {
    case .began:
      let center = phonePoint(event)
      pinch = (center, 120)
      for (pointer, point) in pinchPoints(center: center, distance: 120) {
        control.touch(.down, pointer: pointer, at: point)
      }
    case .changed:
      guard var current = pinch else { return }
      current.distance = min(max(current.distance * (1 + event.magnification), 20), 2000)
      pinch = current
      for (pointer, point) in pinchPoints(center: current.center, distance: current.distance) {
        control.touch(.move, pointer: pointer, at: point)
      }
    case .ended, .cancelled:
      if let current = pinch {
        for (pointer, point) in pinchPoints(center: current.center, distance: current.distance) {
          control.touch(.up, pointer: pointer, at: point)
        }
      }
      pinch = nil
    default:
      break
    }
  }

  private func pinchPoints(center: CGPoint, distance: CGFloat) -> [(Int64, CGPoint)] {
    let half = distance / 2
    func clamp(_ p: CGPoint) -> CGPoint {
      CGPoint(x: min(max(p.x, 0), videoSize.width - 1), y: min(max(p.y, 0), videoSize.height - 1))
    }
    return [
      (ControlChannel.Pointer.pinchA, clamp(CGPoint(x: center.x - half, y: center.y - half))),
      (ControlChannel.Pointer.pinchB, clamp(CGPoint(x: center.x + half, y: center.y + half))),
    ]
  }

  // MARK: Keyboard

  /// Mac key codes with an Android key of their own.
  private static let keys: [UInt16: Int32] = [
    36: 66, 76: 66,  // return, enter
    48: 61,  // tab
    51: 67,  // delete
    117: 112,  // forward delete
    53: 4,  // escape works as Back, as on Android keyboards
    123: 21, 124: 22, 125: 20, 126: 19,  // arrows
    115: 122, 119: 123, 116: 92, 121: 93,  // home, end, page up, page down
  ]

  /// Mac key codes of letters, for Control shortcuts such as Control-C in a terminal app.
  private static let letters: [UInt16: Int32] = [
    0: 29, 11: 30, 8: 31, 2: 32, 14: 33, 3: 34, 5: 35, 4: 36, 34: 37, 38: 38, 40: 39, 37: 40,
    46: 41, 45: 42, 31: 43, 35: 44, 12: 45, 15: 46, 1: 47, 17: 48, 32: 49, 9: 50, 13: 51,
    7: 52, 16: 53, 6: 54,
  ]

  override func keyDown(with event: NSEvent) {
    guard let control else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.command) {
      super.keyDown(with: event)
      return
    }
    if flags.contains(.control), let letter = Self.letters[event.keyCode] {
      control.key(letter, .down, meta: ControlChannel.Meta.ctrl)
      control.key(letter, .up, meta: ControlChannel.Meta.ctrl)
      return
    }
    if !hasMarkedText(), let code = Self.keys[event.keyCode] {
      var meta: Int32 = 0
      if flags.contains(.shift) { meta |= ControlChannel.Meta.shift }
      if flags.contains(.option) { meta |= ControlChannel.Meta.alt }
      heldKeys[event.keyCode] = code
      control.key(code, .down, repeat: event.isARepeat ? 1 : 0, meta: meta)
      return
    }
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    if let code = heldKeys.removeValue(forKey: event.keyCode) {
      control?.key(code, .up)
    }
  }

  // Edit menu: the Mac clipboard and the phone's stay in step.
  @objc func paste(_ sender: Any?) {
    guard let text = NSPasteboard.general.string(forType: .string) else { return }
    control?.setClipboard(text, paste: true)
  }

  @objc func copy(_ sender: Any?) { control?.copyFromPhone(cut: false) }
  @objc func cut(_ sender: Any?) { control?.copyFromPhone(cut: true) }

  @objc override func selectAll(_ sender: Any?) {
    control?.key(29, .down, meta: ControlChannel.Meta.ctrl)
    control?.key(29, .up, meta: ControlChannel.Meta.ctrl)
  }

  @objc func undo(_ sender: Any?) {
    control?.key(54, .down, meta: ControlChannel.Meta.ctrl)
    control?.key(54, .up, meta: ControlChannel.Meta.ctrl)
  }

  // MARK: Text input (so Chinese, Japanese and other input methods work)

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    marked = NSMutableAttributedString()
    control?.type(text)
  }

  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(insertNewline(_:)): control?.tap(66)
    case #selector(deleteBackward(_:)): control?.tap(67)
    case #selector(insertTab(_:)): control?.tap(61)
    default: break
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let attributed = string as? NSAttributedString {
      marked = NSMutableAttributedString(attributedString: attributed)
    } else {
      marked = NSMutableAttributedString(string: string as? String ?? "")
    }
  }

  func unmarkText() { marked = NSMutableAttributedString() }
  func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
  func markedRange() -> NSRange {
    marked.length > 0
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func hasMarkedText() -> Bool { marked.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    // Put the input method's candidates near the bottom of the phone, where its keyboard would be.
    let rect = videoRect
    let local = NSRect(x: rect.minX + 20, y: rect.maxY - 60, width: 1, height: 20)
    guard let window else { return .zero }
    return window.convertToScreen(convert(local, to: nil))
  }
}
