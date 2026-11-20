import AppKit
import CoreMediaIO
import Security
import SystemExtensions
import VideoToolbox

/// The phone's back camera as a camera on the Mac, through PixelMirror Camera,
/// the system extension inside the app. The phone's camera runs only while
/// this is on.
@MainActor
final class Webcam: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
  static let shared = Webcam()
  static let extensionID = "com.reffwu.pixelmirror.camera"

  /// Only a build signed with a profile that allows system extensions can install it.
  static let canInstall: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let value = SecTaskCopyValueForEntitlement(
      task, "com.apple.developer.system-extension.install" as CFString, nil)
    return (value as? Bool) == true
  }()

  /// The phone whose camera is in use.
  @Published private(set) var phoneID: String?
  private var feed: CameraFeed?
  private var waiting: Phone?

  func toggle(_ phone: Phone) {
    if phoneID != nil { return stop() }
    waiting = phone
    // Installing is quick and asks nothing once the camera is allowed.
    let request = OSSystemExtensionRequest.activationRequest(
      forExtensionWithIdentifier: Self.extensionID, queue: .main)
    request.delegate = self
    OSSystemExtensionManager.shared.submitRequest(request)
  }

  func stop() {
    feed?.stop()
    feed = nil
    phoneID = nil
  }

  /// The phone went away.
  func phonesChanged(_ phones: [Phone]) {
    if let phoneID, !phones.contains(where: { $0.id == phoneID }) { stop() }
  }

  private func start(_ phone: Phone) {
    let feed = CameraFeed(transport: phone.transport)
    feed.onEnd = { [weak self, weak feed] error in
      guard let self, let feed, self.feed === feed else { return }
      self.stop()
      if let error { self.alert(String(localized: "Couldn't start the camera"), error) }
    }
    self.feed = feed
    phoneID = phone.id
    feed.start()
  }

  private func alert(_ title: String, _ text: String, settings: Bool = false) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    if settings {
      alert.addButton(withTitle: String(localized: "Open Settings"))
      alert.addButton(withTitle: String(localized: "Cancel"))
    }
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn, settings,
      let url = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Installing

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    MainActor.assumeIsolated {
      waiting = nil
      alert(
        String(localized: "Allow PixelMirror Camera"),
        String(
          localized:
            "In System Settings, allow PixelMirror under Camera Extensions, then choose Use as Webcam again."
        ), settings: true)
    }
  }

  nonisolated func request(
    _ request: OSSystemExtensionRequest,
    didFinishWithResult result: OSSystemExtensionRequest.Result
  ) {
    MainActor.assumeIsolated {
      guard let phone = waiting else { return }
      waiting = nil
      if result == .completed {
        start(phone)
      } else {
        alert(
          String(localized: "Restart your Mac to finish installing PixelMirror Camera."), "")
      }
    }
  }

  nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    MainActor.assumeIsolated {
      waiting = nil
      alert(String(localized: "Couldn't start the camera"), error.localizedDescription)
    }
  }
}

/// Runs the phone's camera with scrcpy, decodes it and pushes the frames to
/// PixelMirror Camera.
final class CameraFeed: @unchecked Sendable {
  private let transport: String
  private let lock = NSLock()
  private var server: Process?
  private var socket: StreamSocket?
  private var forwardPort: UInt16 = 0
  private var stopped = false
  private var serverLog = ""
  private var decoder: VTDecompressionSession?
  private var decoderFormat: CMFormatDescription?
  private var sink: CameraSink?
  /// Called once on the main thread when the feed ends; with a reason if it failed.
  var onEnd: (@MainActor (String?) -> Void)?

  init(transport: String) {
    self.transport = transport
  }

  func start() {
    Thread.detachNewThread { [self] in
      do {
        try run()
        finish(error: nil)
      } catch {
        finish(error: "\(error)")
      }
    }
  }

  func stop() { finish(error: nil) }

  private struct Failure: Error, CustomStringConvertible {
    var description: String
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func run() throws {
    guard let sink = CameraSink() else {
      throw Failure(
        description: String(localized: "PixelMirror Camera isn't ready yet. Try again."))
    }
    lock.lock()
    self.sink = sink
    lock.unlock()

    let remote = "/data/local/tmp/pixelmirror-camera.jar"
    let push = ADB.run(["-s", transport, "push", ADB.server.path, remote], timeout: 40)
    guard push.ok else { throw Failure(description: push.output) }
    let scid = String(format: "%08x", UInt32.random(in: 0..<0x8000_0000))
    let forward = ADB.run(["-s", transport, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
    guard forward.ok,
      let port = UInt16(forward.output.trimmingCharacters(in: .whitespacesAndNewlines))
    else { throw Failure(description: forward.output) }
    forwardPort = port

    // The back camera, 16:9 to fill the picture, at the size the Mac camera has.
    let options = [
      "scid=\(scid)", "log_level=info", "tunnel_forward=true", "video_codec=h264",
      "video_source=camera", "camera_facing=back", "camera_ar=16:9",
      "max_size=\(Camera.width)", "camera_fps=\(Camera.frameRate)", "audio=false",
      "control=false", "video_bit_rate=8000000", "cleanup=true",
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
      self.serverLog = String((self.serverLog + text).suffix(2000))
      self.lock.unlock()
    }
    process.terminationHandler = { [weak self] _ in
      pipe.fileHandleForReading.readabilityHandler = nil
      self?.finish(error: nil)
    }
    try process.run()
    lock.lock()
    server = process
    lock.unlock()

    var video: StreamSocket?
    let deadline = Date().addingTimeInterval(15)
    while video == nil, Date() < deadline, !isStopped {
      if let socket = StreamSocket.connect(port: port), socket.read(1) != nil {
        video = socket
      } else {
        Thread.sleep(forTimeInterval: 0.1)
      }
    }
    guard let video else {
      if isStopped { return }
      lock.lock()
      let log = serverLog
      lock.unlock()
      throw Failure(description: log.isEmpty ? "The phone did not answer." : log)
    }
    lock.lock()
    socket = video
    lock.unlock()
    guard video.read(64) != nil, let codec = video.read(4), codec.bigEndianUInt32 == 0x6832_3634
    else { return }

    sink.start()
    let packetizer = H264Packetizer()
    while let header = video.read(12) {
      if header[header.startIndex] & 0x80 != 0 { continue }
      let flags = header.prefix(8).bigEndianUInt64
      guard let packet = video.read(Int(header.suffix(4).bigEndianUInt32)) else { break }
      if flags & (1 << 62) != 0 {
        packetizer.configure(with: packet)
        continue
      }
      if let format = packetizer.format, let sample = packetizer.sample(from: packet) {
        decode(sample, format: format, into: sink)
      }
    }
  }

  /// Decodes straight to the camera's size and format.
  private func decode(_ sample: CMSampleBuffer, format: CMFormatDescription, into sink: CameraSink)
  {
    if decoder == nil
      || decoderFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) })
        == true
    {
      if let decoder { VTDecompressionSessionInvalidate(decoder) }
      let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(Camera.width),
        kCVPixelBufferHeightKey as String: Int(Camera.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      var session: VTDecompressionSession?
      VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
        imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
        decompressionSessionOut: &session)
      decoder = session
      decoderFormat = format
    }
    guard let decoder else { return }
    VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
      status, _, image, _, _ in
      guard status == noErr, let image else { return }
      sink.send(image)
    }
  }

  private func finish(error: String?) {
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    stopped = true
    let process = server
    let socket = self.socket
    let sink = self.sink
    lock.unlock()
    socket?.close()
    if let process, process.isRunning { process.terminate() }
    sink?.stop()
    if forwardPort != 0 {
      let port = forwardPort
      let transport = transport
      DispatchQueue.global().async {
        ADB.run(["-s", transport, "forward", "--remove", "tcp:\(port)"], timeout: 3)
      }
    }
    DispatchQueue.main.async { self.onEnd?(error) }
  }
}

/// PixelMirror Camera's input, found with Core Media I/O.
final class CameraSink: @unchecked Sendable {
  private let device: CMIOObjectID
  private let stream: CMIOStreamID
  private var queue: CMSimpleQueue?
  private var format: CMFormatDescription?
  private let lock = NSLock()

  init?() {
    guard
      let device = Self.objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        .first(where: { Self.name(of: $0) == Camera.name })
    else { return nil }
    // The extension adds its output first and this input second.
    let streams = Self.objects(device, kCMIODevicePropertyStreams)
    guard streams.count > 1 else { return nil }
    self.device = device
    stream = streams[1]
  }

  func start() {
    let pointer = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
    defer { pointer.deallocate() }
    guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, pointer) == noErr,
      let queue = pointer.pointee?.takeRetainedValue()
    else { return }
    lock.lock()
    self.queue = queue
    lock.unlock()
    CMIODeviceStartStream(device, stream)
  }

  func stop() {
    CMIODeviceStopStream(device, stream)
    lock.lock()
    queue = nil
    lock.unlock()
  }

  func send(_ image: CVImageBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
    if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: image) {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: image, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(
      duration: Camera.frameDuration,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: image, formatDescription: format,
      sampleTiming: &timing, sampleBufferOut: &sample)
    if let sample {
      CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }
  }

  private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(selector),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else {
      return []
    }
    return ids
  }

  private static func name(of object: CMIOObjectID) -> String? {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var name: Unmanaged<CFString>?
    var used: UInt32 = 0
    let status = withUnsafeMutablePointer(to: &name) {
      CMIOObjectGetPropertyData(
        object, &address, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, $0)
    }
    guard status == noErr else { return nil }
    return name?.takeRetainedValue() as String?
  }
}

/// What PixelMirror Camera offers; the extension uses the same values.
enum Camera {
  static let name = "PixelMirror Camera"
  static let width: Int32 = 1920
  static let height: Int32 = 1080
  static let frameRate: Int32 = 30
  static let frameDuration = CMTime(value: 1, timescale: frameRate)
}
