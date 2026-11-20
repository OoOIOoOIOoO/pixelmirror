import AppKit
import Foundation

/// scrcpy's control protocol: input going to the phone, clipboard coming back.
final class ControlChannel: @unchecked Sendable {
  enum Action: UInt8 {
    case down = 0
    case up = 1
    case move = 2
  }

  enum Key {
    static let home: Int32 = 3
    static let back: Int32 = 4
    static let appSwitch: Int32 = 187
    static let volumeUp: Int32 = 24
    static let volumeDown: Int32 = 25
    static let power: Int32 = 26
    static let copy: Int32 = 278
    static let cut: Int32 = 277
  }

  enum Meta {
    static let shift: Int32 = 0x1
    static let alt: Int32 = 0x2
    static let ctrl: Int32 = 0x1000
  }

  enum Pointer {
    static let mouse: Int64 = -2  // a finger that follows the mouse
    static let scroll: Int64 = -5  // a finger that follows two-finger trackpad scrolling
    static let pinchA: Int64 = -3
    static let pinchB: Int64 = -4
  }

  var videoSize = CGSize.zero
  private var socket: StreamSocket?
  private let queue = DispatchQueue(label: "com.reffwu.pixelmirror.control")
  private var clipboardSequence: Int64 = 0

  func attach(_ socket: StreamSocket) {
    queue.sync { self.socket = socket }
  }

  // MARK: - Messages

  func key(_ code: Int32, _ action: Action, repeat count: Int32 = 0, meta: Int32 = 0) {
    var m = Message(0)
    m.u8(action.rawValue)
    m.i32(code)
    m.i32(count)
    m.i32(meta)
    send(m)
  }

  func tap(_ code: Int32, meta: Int32 = 0) {
    key(code, .down, meta: meta)
    key(code, .up, meta: meta)
  }

  func text(_ text: String) {
    var m = Message(1)
    m.string(text)
    send(m)
  }

  func touch(_ action: Action, pointer: Int64, at point: CGPoint, pressure: Float = 1) {
    guard videoSize.width > 0 else { return }
    var m = Message(2)
    m.u8(action.rawValue)
    m.i64(pointer)
    position(&m, point)
    m.u16(action == .up ? 0 : UInt16(min(max(pressure, 0), 1) * 65535))
    m.i32(0)  // action button
    m.i32(0)  // buttons
    send(m)
  }

  func scroll(at point: CGPoint, horizontal: CGFloat, vertical: CGFloat) {
    guard videoSize.width > 0 else { return }
    var m = Message(3)
    position(&m, point)
    m.i16(Self.fixed(horizontal / 16))
    m.i16(Self.fixed(vertical / 16))
    m.i32(0)
    send(m)
  }

  /// Back when the screen is on; turns the screen on when it is off.
  func backOrScreenOn() {
    for action in [Action.down, .up] {
      var m = Message(4)
      m.u8(action.rawValue)
      send(m)
    }
  }

  func expandNotifications() { send(Message(5)) }

  /// Copies the phone's selection: the phone sends its clipboard back afterwards.
  func copyFromPhone(cut: Bool) {
    var m = Message(8)
    m.u8(cut ? 2 : 1)
    send(m)
  }

  /// Puts text on the phone's clipboard and optionally pastes it.
  func setClipboard(_ text: String, paste: Bool) {
    clipboardSequence += 1
    var m = Message(9)
    m.i64(clipboardSequence)
    m.u8(paste ? 1 : 0)
    m.string(text)
    send(m)
  }

  /// Turns the phone's own screen off or on while mirroring continues.
  func setScreenPower(on: Bool) {
    var m = Message(10)
    m.u8(on ? 1 : 0)
    send(m)
  }

  func rotate() { send(Message(11)) }

  /// Types text the way a person would expect: plain characters directly,
  /// anything else (Chinese, emoji, accents) through the clipboard.
  func type(_ string: String) {
    guard !string.isEmpty else { return }
    if string.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }) {
      text(string)
    } else {
      setClipboard(string, paste: true)
    }
  }

  // MARK: - Device messages

  func readDeviceMessages() {
    guard let socket = queue.sync(execute: { self.socket }) else { return }
    while let type = socket.read(1)?.first {
      switch type {
      case 0:  // clipboard
        guard let length = socket.read(4)?.bigEndianUInt32,
          let data = socket.read(Int(length))
        else { return }
        let text = String(decoding: data, as: UTF8.self)
        DispatchQueue.main.async {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      case 1:  // clipboard acknowledgement
        guard socket.read(8) != nil else { return }
      case 2:  // UHID output
        guard socket.read(2) != nil, let size = socket.read(2)?.bigEndianUInt32,
          socket.read(Int(size)) != nil
        else { return }
      default:
        return
      }
    }
  }

  // MARK: - Encoding

  private func position(_ m: inout Message, _ point: CGPoint) {
    m.i32(Int32(point.x.rounded()))
    m.i32(Int32(point.y.rounded()))
    m.u16(UInt16(videoSize.width))
    m.u16(UInt16(videoSize.height))
  }

  private static func fixed(_ value: CGFloat) -> Int16 {
    let clamped = min(max(value, -1), 1)
    return Int16(clamping: Int((clamped * 0x8000).rounded()))
  }

  private func send(_ message: Message) {
    queue.async { [weak self] in
      _ = self?.socket?.write(message.data)
    }
  }

  private struct Message {
    var data: Data
    init(_ type: UInt8) { data = Data([type]) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v.bigEndian) }
    mutating func i16(_ v: Int16) { append(v.bigEndian) }
    mutating func i32(_ v: Int32) { append(v.bigEndian) }
    mutating func i64(_ v: Int64) { append(v.bigEndian) }
    mutating func string(_ s: String) {
      let bytes = Data(s.utf8)
      i32(Int32(bytes.count))
      data.append(bytes)
    }
    private mutating func append<T>(_ value: T) {
      withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
  }
}
