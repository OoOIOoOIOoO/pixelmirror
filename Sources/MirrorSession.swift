import AVFoundation
import AppKit
import CoreMedia
import Foundation

@MainActor
protocol MirrorSessionDelegate: AnyObject {
  /// Called on the main thread.
  func sessionDidStart(_ session: MirrorSession, deviceName: String)
  func session(_ session: MirrorSession, videoSizeChanged size: CGSize)
  func sessionDidEnd(_ session: MirrorSession, error: String?)
  /// The phone refuses touch and keys from the computer (Xiaomi, OPPO and others need a switch).
  func sessionInputBlocked(_ session: MirrorSession)
}

/// Runs the scrcpy server on the phone and keeps its three streams going:
/// video into a display layer, audio into the speakers, input back to the phone.
final class MirrorSession: @unchecked Sendable {
  let transport: String
  let isUSB: Bool
  let renderer: AVSampleBufferDisplayLayer
  weak var delegate: MirrorSessionDelegate?

  private(set) var videoSize = CGSize.zero
  private let control = ControlChannel()
  private let audio = AudioPlayer()
  private var server: Process?
  private var sockets: [StreamSocket] = []
  private var forwardPort: UInt16 = 0
  private var stopped = false
  private let lock = NSLock()
  private var serverLog = ""
  private var inputBlocked = false

  init(transport: String, isUSB: Bool, renderer: AVSampleBufferDisplayLayer) {
    self.transport = transport
    self.isUSB = isUSB
    self.renderer = renderer
  }

  var input: ControlChannel { control }

  func start() {
    Thread.detachNewThread { [self] in
      do {
        try run()
      } catch {
        finish(error: "\(error)")
      }
    }
  }

  func stop() {
    finish(error: nil)
  }

  // MARK: - Startup

  private struct Failure: Error, CustomStringConvertible {
    var description: String
  }

  private func run() throws {
    let remote = "/data/local/tmp/pixelmirror-server.jar"
    let push = ADB.run(["-s", transport, "push", ADB.server.path, remote], timeout: 40)
    guard push.ok else { throw Failure(description: "push: \(push.output)") }

    let scid = String(format: "%08x", UInt32.random(in: 0..<0x8000_0000))
    let forward = ADB.run(["-s", transport, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
    guard forward.ok,
      let port = UInt16(forward.output.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw Failure(description: "forward: \(forward.output)") }
    forwardPort = port

    let options = [
      "scid=\(scid)", "log_level=info", "tunnel_forward=true",
      "video_codec=h264", "audio_codec=raw", "audio_source=playback", "audio_dup=false",
      // A cable carries the full resolution; Wi-Fi gets a size and rate it can keep up with.
      "max_size=\(isUSB ? 0 : 1920)", "video_bit_rate=\(isUSB ? 16_000_000 : 8_000_000)",
      "max_fps=60", "stay_awake=true", "clipboard_autosync=true", "power_off_on_close=false",
      "cleanup=true",
    ]
    let command =
      "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server \(ADB.serverVersion) "
      + options.joined(separator: " ")
    let process = ADB.spawn(["-s", transport, "shell", command])
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let text = String(decoding: handle.availableData, as: UTF8.self)
      guard let self, !text.isEmpty else { return }
      self.lock.lock()
      self.serverLog = String((self.serverLog + text).suffix(4000))
      let blocked = !self.inputBlocked && self.serverLog.contains("INJECT_EVENTS")
      if blocked { self.inputBlocked = true }
      self.lock.unlock()
      if blocked { DispatchQueue.main.async { self.delegate?.sessionInputBlocked(self) } }
    }
    process.terminationHandler = { [weak self] _ in
      pipe.fileHandleForReading.readabilityHandler = nil
      self?.finish(error: nil)
    }
    try process.run()
    lock.lock()
    server = process
    let cancelled = stopped
    lock.unlock()
    if cancelled { throw Failure(description: "stopped") }

    // The server listens a moment after it starts. With a forward tunnel the
    // connection succeeds at once, so wait for the dummy byte it sends.
    var video: StreamSocket?
    let deadline = Date().addingTimeInterval(15)
    while video == nil, Date() < deadline, !isStopped {
      if let socket = StreamSocket.connect(port: port), socket.read(1) != nil {
        video = socket
      } else {
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
    guard let video else { throw Failure(description: "The phone did not answer. \(log)") }
    guard let audioSocket = StreamSocket.connect(port: port),
      let controlSocket = StreamSocket.connect(port: port, noDelay: true)
    else { throw Failure(description: "Could not open the audio and control channels.") }
    lock.lock()
    sockets = [video, audioSocket, controlSocket]
    lock.unlock()

    guard let meta = video.read(64) else { throw Failure(description: "No device name.") }
    let name = String(decoding: meta.prefix { $0 != 0 }, as: UTF8.self)
    control.attach(controlSocket)
    DispatchQueue.main.async { self.delegate?.sessionDidStart(self, deviceName: name) }

    Thread.detachNewThread { [self] in readAudio(audioSocket) }
    Thread.detachNewThread { [self] in control.readDeviceMessages() }
    readVideo(video)
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private var log: String {
    lock.lock()
    defer { lock.unlock() }
    return serverLog
  }

  private func finish(error: String?) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    let open = sockets
    let process = server
    lock.unlock()

    for socket in open { socket.close() }
    if let process, process.isRunning { process.terminate() }
    audio.stop()
    if forwardPort != 0 {
      let port = forwardPort
      let transport = transport
      DispatchQueue.global().async {
        ADB.run(["-s", transport, "forward", "--remove", "tcp:\(port)"], timeout: 3)
      }
    }
    DispatchQueue.main.async { self.delegate?.sessionDidEnd(self, error: error) }
  }

  // MARK: - Video

  private func readVideo(_ socket: StreamSocket) {
    guard let codec = socket.read(4), codec.bigEndianUInt32 == 0x6832_3634 else {
      finish(error: "Unsupported video codec.")
      return
    }
    let decoder = H264Packetizer()
    while let header = socket.read(12) {
      if header[header.startIndex] & 0x80 != 0 {
        let width = header.subdata(in: header.startIndex + 4..<header.startIndex + 8)
          .bigEndianUInt32
        let height = header.subdata(in: header.startIndex + 8..<header.startIndex + 12)
          .bigEndianUInt32
        let size = CGSize(width: Int(width), height: Int(height))
        videoSize = size
        control.videoSize = size
        DispatchQueue.main.async { self.delegate?.session(self, videoSizeChanged: size) }
        continue
      }
      let flags = header.prefix(8).bigEndianUInt64
      let length = Int(header.suffix(4).bigEndianUInt32)
      guard let packet = socket.read(length) else { break }
      if flags & (1 << 62) != 0 {
        decoder.configure(with: packet)
        renderer.sampleBufferRenderer.flush()
        continue
      }
      if let sample = decoder.sample(from: packet) {
        if renderer.sampleBufferRenderer.status == .failed { renderer.sampleBufferRenderer.flush() }
        renderer.sampleBufferRenderer.enqueue(sample)
      }
    }
    finish(error: nil)
  }

  // MARK: - Audio

  private func readAudio(_ socket: StreamSocket) {
    guard let codec = socket.read(4), codec.bigEndianUInt32 == 0x0072_6177 else { return }
    audio.start()
    while let header = socket.read(12) {
      let length = Int(header.suffix(4).bigEndianUInt32)
      guard let packet = socket.read(length) else { break }
      audio.push(packet)
    }
  }
}

// MARK: - H.264

/// Turns MediaCodec's Annex B packets into sample buffers the display layer decodes in hardware.
final class H264Packetizer {
  private var format: CMVideoFormatDescription?

  func configure(with packet: Data) {
    let units = Self.units(in: packet)
    guard let sps = units.first(where: { $0.first.map { $0 & 0x1F } == 7 }),
      let pps = units.first(where: { $0.first.map { $0 & 0x1F } == 8 })
    else { return }
    var description: CMVideoFormatDescription?
    sps.withUnsafeBytes { spsBytes in
      pps.withUnsafeBytes { ppsBytes in
        let pointers = [
          spsBytes.bindMemory(to: UInt8.self).baseAddress!,
          ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
        ]
        let sizes = [sps.count, pps.count]
        CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
      }
    }
    if let description { format = description }
  }

  func sample(from packet: Data) -> CMSampleBuffer? {
    guard let format else { return nil }
    var avcc = Data(capacity: packet.count + 16)
    for unit in Self.units(in: packet) {
      let type = (unit.first ?? 0) & 0x1F
      if type == 7 || type == 8 || type == 9 { continue }
      var length = UInt32(unit.count).bigEndian
      avcc.append(Data(bytes: &length, count: 4))
      avcc.append(unit)
    }
    guard !avcc.isEmpty else { return nil }

    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        == noErr, let block
    else { return nil }
    avcc.withUnsafeBytes { bytes in
      _ = CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: avcc.count)
    }
    var sample: CMSampleBuffer?
    var size = avcc.count
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
      let sample
    else { return nil }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  /// NAL units between Annex B start codes.
  static func units(in data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var units: [Data] = []
    var start = -1
    var i = 0
    while i + 2 < bytes.count {
      if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
        if start >= 0 {
          var end = i
          if end > start, bytes[end - 1] == 0 { end -= 1 }
          units.append(Data(bytes[start..<end]))
        }
        i += 3
        start = i
        continue
      }
      i += 1
    }
    if start >= 0, start < bytes.count { units.append(Data(bytes[start...])) }
    return units
  }
}

// MARK: - Sockets

final class StreamSocket: @unchecked Sendable {
  private let fd: Int32
  private let lock = NSLock()
  private var closed = false

  private init(fd: Int32) { self.fd = fd }

  static func connect(port: UInt16, noDelay: Bool = false) -> StreamSocket? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(fd)
      return nil
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    if noDelay {
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }
    return StreamSocket(fd: fd)
  }

  /// Exactly `count` bytes, or nil once the stream ends.
  func read(_ count: Int) -> Data? {
    guard count > 0 else { return Data() }
    var data = Data(count: count)
    var received = 0
    let ok = data.withUnsafeMutableBytes { buffer -> Bool in
      while received < count {
        let n = recv(fd, buffer.baseAddress! + received, count - received, 0)
        if n <= 0 { return false }
        received += n
      }
      return true
    }
    return ok ? data : nil
  }

  @discardableResult
  func write(_ data: Data) -> Bool {
    data.withUnsafeBytes { buffer in
      var sent = 0
      while sent < data.count {
        let n = send(fd, buffer.baseAddress! + sent, data.count - sent, 0)
        if n <= 0 { return false }
        sent += n
      }
      return true
    }
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
  }
}

extension Data {
  var bigEndianUInt32: UInt32 { reduce(0) { $0 << 8 | UInt32($1) } }
  var bigEndianUInt64: UInt64 { reduce(0) { $0 << 8 | UInt64($1) } }
}
