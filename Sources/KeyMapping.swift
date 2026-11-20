import AppKit
import SwiftUI

/// Keys placed on a game's screen: each one taps its point, and W A S D steer a joystick.
/// Saved per app; points are fractions of the screen, so they survive any window size.
struct KeyMap: Codable, Equatable {
  var enabled = true
  var taps: [Tap] = []
  var joystick: Joystick?

  struct Tap: Codable, Equatable, Identifiable {
    var id = UUID()
    var keyCode: UInt16
    var label: String
    var x: Double
    var y: Double
  }

  struct Joystick: Codable, Equatable {
    var x: Double
    var y: Double
    var radius: Double  // a fraction of the screen's width
  }

  static let joystickKeys: [UInt16: CGVector] = [
    13: CGVector(dx: 0, dy: -1), 1: CGVector(dx: 0, dy: 1),  // W, S
    0: CGVector(dx: -1, dy: 0), 2: CGVector(dx: 1, dy: 0),  // A, D
  ]

  var isEmpty: Bool { taps.isEmpty && joystick == nil }

  static func load(_ package: String) -> KeyMap? {
    guard let data = UserDefaults.standard.data(forKey: "keyMap-\(package)") else { return nil }
    return try? JSONDecoder().decode(KeyMap.self, from: data)
  }

  func save(_ package: String) {
    var saved = Set(UserDefaults.standard.stringArray(forKey: "keyMapApps") ?? [])
    if isEmpty {
      UserDefaults.standard.removeObject(forKey: "keyMap-\(package)")
      saved.remove(package)
    } else if let data = try? JSONEncoder().encode(self) {
      UserDefaults.standard.set(data, forKey: "keyMap-\(package)")
      saved.insert(package)
    }
    UserDefaults.standard.set(Array(saved), forKey: "keyMapApps")
  }

  static var anySaved: Bool {
    !(UserDefaults.standard.stringArray(forKey: "keyMapApps") ?? []).isEmpty
  }

  /// The name of a key as printed on it.
  static func label(for event: NSEvent) -> String {
    switch event.keyCode {
    case 49: return "␣"
    case 36: return "↩"
    case 48: return "⇥"
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    default:
      return (event.charactersIgnoringModifiers ?? "").uppercased()
    }
  }
}

/// Plays a key map: turns key presses into fingers on the phone.
@MainActor
final class KeyMapper {
  var map = KeyMap()
  weak var control: ControlChannel?
  var videoSize = CGSize.zero
  private var held: Set<UInt16> = []
  private var stick: Set<UInt16> = []

  private static let stickPointer: Int64 = 90
  private static func pointer(_ index: Int) -> Int64 { Int64(100 + index) }

  var isActive: Bool { map.enabled && !map.isEmpty }

  /// True when the key belongs to the map, so it is not typed as well.
  func keyDown(_ event: NSEvent) -> Bool {
    guard isActive, let control, videoSize.width > 0,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    else { return false }
    if let joystick = map.joystick, KeyMap.joystickKeys[event.keyCode] != nil {
      if !event.isARepeat {
        let wasIdle = stick.isEmpty
        stick.insert(event.keyCode)
        if wasIdle { control.touch(.down, pointer: Self.stickPointer, at: point(joystick, nil)) }
        control.touch(.move, pointer: Self.stickPointer, at: point(joystick, direction))
      }
      return true
    }
    guard let index = map.taps.firstIndex(where: { $0.keyCode == event.keyCode }) else {
      return false
    }
    if !event.isARepeat, held.insert(event.keyCode).inserted {
      control.touch(.down, pointer: Self.pointer(index), at: point(map.taps[index]))
    }
    return true
  }

  func keyUp(_ event: NSEvent) -> Bool {
    guard let control else { return false }
    if stick.remove(event.keyCode) != nil, let joystick = map.joystick {
      if stick.isEmpty {
        control.touch(.up, pointer: Self.stickPointer, at: point(joystick, nil))
      } else {
        control.touch(.move, pointer: Self.stickPointer, at: point(joystick, direction))
      }
      return true
    }
    guard held.remove(event.keyCode) != nil,
      let index = map.taps.firstIndex(where: { $0.keyCode == event.keyCode })
    else { return false }
    control.touch(.up, pointer: Self.pointer(index), at: point(map.taps[index]))
    return true
  }

  /// Lifts every finger, such as when the window loses focus mid-press.
  func releaseAll() {
    guard let control else { return }
    for code in held {
      if let index = map.taps.firstIndex(where: { $0.keyCode == code }) {
        control.touch(.up, pointer: Self.pointer(index), at: point(map.taps[index]))
      }
    }
    if !stick.isEmpty, let joystick = map.joystick {
      control.touch(.up, pointer: Self.stickPointer, at: point(joystick, nil))
    }
    held = []
    stick = []
  }

  private var direction: CGVector {
    var sum = CGVector.zero
    for code in stick {
      if let v = KeyMap.joystickKeys[code] {
        sum.dx += v.dx
        sum.dy += v.dy
      }
    }
    let length = (sum.dx * sum.dx + sum.dy * sum.dy).squareRoot()
    return length > 0 ? CGVector(dx: sum.dx / length, dy: sum.dy / length) : .zero
  }

  private func point(_ tap: KeyMap.Tap) -> CGPoint {
    CGPoint(x: tap.x * videoSize.width, y: tap.y * videoSize.height)
  }

  private func point(_ joystick: KeyMap.Joystick, _ direction: CGVector?) -> CGPoint {
    let reach = joystick.radius * videoSize.width
    return CGPoint(
      x: joystick.x * videoSize.width + (direction?.dx ?? 0) * reach,
      y: joystick.y * videoSize.height + (direction?.dy ?? 0) * reach)
  }
}

// MARK: - Editing

/// Drawn over the phone: while editing it takes the mouse and keyboard to place keys;
/// otherwise it only shows faint keys and lets everything through.
final class KeyMapView: NSView {
  var map = KeyMap() { didSet { needsDisplay = true } }
  var videoRect = CGRect.zero { didSet { needsDisplay = true } }
  var editing = false {
    didSet {
      selected = nil
      needsDisplay = true
    }
  }
  var onChange: ((KeyMap) -> Void)?
  var onDone: (() -> Void)?

  /// A tap waiting for its key, or one picked to move, rename or delete.
  private var selected: UUID?
  private var draggingStick = false
  private var dragOffset = CGSize.zero

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { editing }

  override func hitTest(_ point: NSPoint) -> NSView? {
    editing ? super.hitTest(point) : nil
  }

  private func viewPoint(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: videoRect.minX + x * videoRect.width, y: videoRect.minY + y * videoRect.height)
  }

  private func fraction(_ point: CGPoint) -> (Double, Double) {
    let x = (point.x - videoRect.minX) / max(videoRect.width, 1)
    let y = (point.y - videoRect.minY) / max(videoRect.height, 1)
    return (min(max(x, 0), 1), min(max(y, 0), 1))
  }

  private let tapRadius: CGFloat = 17

  override func draw(_ dirtyRect: NSRect) {
    guard editing || map.enabled else { return }
    if editing {
      NSColor.black.withAlphaComponent(0.35).setFill()
      videoRect.fill()
    }
    let alpha: CGFloat = editing ? 1 : 0.5
    if let stick = map.joystick {
      let center = viewPoint(stick.x, stick.y)
      let r = stick.radius * videoRect.width
      let circle = NSBezierPath(
        ovalIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
      NSColor.white.withAlphaComponent(0.18 * alpha).setFill()
      circle.fill()
      NSColor.white.withAlphaComponent(0.8 * alpha).setStroke()
      circle.lineWidth = 1.5
      circle.stroke()
      for (text, dx, dy) in [("W", 0.0, -1.0), ("A", -1, 0), ("S", 0, 1), ("D", 1, 0)] {
        drawLabel(
          text, at: CGPoint(x: center.x + dx * r * 0.65, y: center.y + dy * r * 0.65),
          alpha: alpha, fill: false)
      }
    }
    for tap in map.taps {
      let center = viewPoint(tap.x, tap.y)
      let rect = CGRect(
        x: center.x - tapRadius, y: center.y - tapRadius, width: tapRadius * 2,
        height: tapRadius * 2)
      let circle = NSBezierPath(ovalIn: rect)
      let isSelected = editing && tap.id == selected
      (isSelected ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.55))
        .withAlphaComponent(alpha).setFill()
      circle.fill()
      NSColor.white.withAlphaComponent(0.9 * alpha).setStroke()
      circle.lineWidth = 1.5
      circle.stroke()
      drawLabel(tap.label.isEmpty ? "?" : tap.label, at: center, alpha: alpha, fill: true)
    }
  }

  private func drawLabel(_ text: String, at center: CGPoint, alpha: CGFloat, fill: Bool) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    if let tap = map.taps.last(where: {
      hypot(viewPoint($0.x, $0.y).x - point.x, viewPoint($0.x, $0.y).y - point.y) <= tapRadius + 4
    }) {
      selected = tap.id
      let center = viewPoint(tap.x, tap.y)
      dragOffset = CGSize(width: point.x - center.x, height: point.y - center.y)
    } else if let stick = map.joystick,
      hypot(viewPoint(stick.x, stick.y).x - point.x, viewPoint(stick.x, stick.y).y - point.y)
        <= stick.radius * videoRect.width
    {
      selected = nil
      draggingStick = true
      let center = viewPoint(stick.x, stick.y)
      dragOffset = CGSize(width: point.x - center.x, height: point.y - center.y)
    } else if videoRect.contains(point) {
      // A new key: it waits for the key that will press it.
      let (x, y) = fraction(point)
      let tap = KeyMap.Tap(keyCode: UInt16.max, label: "", x: x, y: y)
      map.taps.append(tap)
      selected = tap.id
      dragOffset = .zero
      onChange?(map)
    } else {
      selected = nil
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let (x, y) = fraction(CGPoint(x: point.x - dragOffset.width, y: point.y - dragOffset.height))
    if draggingStick {
      map.joystick?.x = x
      map.joystick?.y = y
    } else if let index = map.taps.firstIndex(where: { $0.id == selected }) {
      map.taps[index].x = x
      map.taps[index].y = y
    }
  }

  override func mouseUp(with event: NSEvent) {
    draggingStick = false
    onChange?(map)
  }

  // MARK: Keys

  override func keyDown(with event: NSEvent) {
    guard let index = map.taps.firstIndex(where: { $0.id == selected }) else {
      // With no key picked, Return or Escape finishes.
      if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 53 { onDone?() }
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {  // delete removes the key
      map.taps.remove(at: index)
      selected = nil
    } else if event.keyCode == 53 {  // escape
      if map.taps[index].keyCode == UInt16.max { map.taps.remove(at: index) }
      selected = nil
    } else if event.modifierFlags.intersection([.command, .control]).isEmpty,
      KeyMap.joystickKeys[event.keyCode] == nil || map.joystick == nil
    {
      // One key, one place: taking a key moves it here.
      map.taps.removeAll { $0.keyCode == event.keyCode && $0.id != selected }
      if let index = map.taps.firstIndex(where: { $0.id == selected }) {
        map.taps[index].keyCode = event.keyCode
        map.taps[index].label = KeyMap.label(for: event)
      }
      selected = nil
    } else {
      NSSound.beep()
    }
    onChange?(map)
  }

  /// Keys without a key yet are dropped when editing ends.
  func finish() -> KeyMap {
    map.taps.removeAll { $0.keyCode == UInt16.max }
    return map
  }
}

/// The bar under the phone while keys are being placed.
struct KeyMapBar: View {
  var map: KeyMap
  var setJoystick: (Bool) -> Void
  var setEnabled: (Bool) -> Void
  var clear: () -> Void
  var done: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text("Click to place a key, then press it. Drag to move, Delete to remove.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 10) {
        Toggle(isOn: Binding(get: { map.joystick != nil }, set: setJoystick)) {
          Text(verbatim: "W A S D")
        }
        .toggleStyle(.button)
        .fixedSize()
        .help(String(localized: "Joystick"))
        Toggle("Use in This App", isOn: Binding(get: { map.enabled }, set: setEnabled))
          .toggleStyle(.switch)
          .controlSize(.mini)
          .fixedSize()
        Spacer(minLength: 0)
        Button("Clear", action: clear)
          .disabled(map.isEmpty)
        Button("Done", action: done)
          .buttonStyle(.borderedProminent)
      }
      .controlSize(.small)
    }
    .padding(12)
    .frame(maxWidth: 340)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .environment(\.colorScheme, .dark)
  }
}
