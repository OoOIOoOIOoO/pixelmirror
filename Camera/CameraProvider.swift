import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio

/// PixelMirror's virtual camera. The app pushes the phone's camera into the
/// sink stream; apps that use the camera read the source stream. Until the app
/// sends frames, they see black.
enum Camera {
  static let name = "PixelMirror Camera"
  static let width: Int32 = 1920
  static let height: Int32 = 1080
  static let frameRate: Int32 = 30
  static let frameDuration = CMTime(value: 1, timescale: frameRate)
}

final class CameraProvider: NSObject, CMIOExtensionProviderSource {
  private(set) var provider: CMIOExtensionProvider!
  private var device: CameraDevice!

  init(clientQueue: DispatchQueue?) {
    super.init()
    provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
    device = CameraDevice()
    do {
      try provider.addDevice(device.device)
    } catch {
      fatalError("Couldn't add the camera: \(error)")
    }
  }

  func connect(to client: CMIOExtensionClient) throws {}
  func disconnect(from client: CMIOExtensionClient) {}

  var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

  func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
    -> CMIOExtensionProviderProperties
  {
    let result = CMIOExtensionProviderProperties(dictionary: [:])
    if properties.contains(.providerManufacturer) { result.manufacturer = "Reff Wu" }
    return result
  }

  func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class CameraDevice: NSObject, CMIOExtensionDeviceSource {
  private(set) var device: CMIOExtensionDevice!
  private var source: SourceStream!
  private var sink: SinkStream!
  private let queue = DispatchQueue(label: "com.reffwu.pixelmirror.camera.frames")
  private var timer: DispatchSourceTimer?
  private var watchers = 0
  private var lastFrame: UInt64 = 0
  private var black: CVPixelBuffer?
  private var blackFormat: CMFormatDescription?

  override init() {
    super.init()
    device = CMIOExtensionDevice(
      localizedName: Camera.name,
      deviceID: UUID(uuidString: "6F1E3C2A-7B51-4D0E-9A44-0C8E6B2F1A70")!, legacyDeviceID: nil,
      source: self)
    var description: CMFormatDescription?
    CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: Camera.width,
      height: Camera.height, extensions: nil, formatDescriptionOut: &description)
    let format = CMIOExtensionStreamFormat(
      formatDescription: description!, maxFrameDuration: Camera.frameDuration,
      minFrameDuration: Camera.frameDuration, validFrameDurations: nil)
    source = SourceStream(format: format, device: self)
    sink = SinkStream(format: format, device: self)
    do {
      // The app finds the sink as the second stream.
      try device.addStream(source.stream)
      try device.addStream(sink.stream)
    } catch {
      fatalError("Couldn't add the camera's streams: \(error)")
    }
    makeBlack()
  }

  var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

  func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
    -> CMIOExtensionDeviceProperties
  {
    let result = CMIOExtensionDeviceProperties(dictionary: [:])
    if properties.contains(.deviceTransportType) {
      result.transportType = kIOAudioDeviceTransportTypeVirtual
    }
    if properties.contains(.deviceModel) { result.model = Camera.name }
    return result
  }

  func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

  // MARK: - Frames

  /// An app started watching: send black until the phone's frames arrive.
  func watcherStarted() {
    queue.async {
      self.watchers += 1
      guard self.timer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(deadline: .now(), repeating: 1.0 / Double(Camera.frameRate))
      timer.setEventHandler { [weak self] in self?.sendBlackIfIdle() }
      timer.resume()
      self.timer = timer
    }
  }

  func watcherStopped() {
    queue.async {
      self.watchers = max(0, self.watchers - 1)
      guard self.watchers == 0 else { return }
      self.timer?.cancel()
      self.timer = nil
    }
  }

  /// A frame from the app, passed on to everyone watching.
  func received(_ buffer: CMSampleBuffer) {
    queue.async {
      let now = mach_absolute_time()
      self.lastFrame = now
      guard self.watchers > 0 else { return }
      self.source.stream.send(
        buffer, discontinuity: [], hostTimeInNanoseconds: Self.nanoseconds(now))
    }
  }

  private func sendBlackIfIdle() {
    let now = mach_absolute_time()
    guard Self.nanoseconds(now - lastFrame) > 500_000_000, let black, let blackFormat else {
      return
    }
    var timing = CMSampleTimingInfo(
      duration: Camera.frameDuration,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: black, formatDescription: blackFormat,
      sampleTiming: &timing, sampleBufferOut: &sample)
    if let sample {
      source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: Self.nanoseconds(now))
    }
  }

  private func makeBlack() {
    let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    CVPixelBufferCreate(
      kCFAllocatorDefault, Int(Camera.width), Int(Camera.height), kCVPixelFormatType_32BGRA,
      attributes as CFDictionary, &black)
    guard let black else { return }
    CVPixelBufferLockBaseAddress(black, [])
    if let base = CVPixelBufferGetBaseAddress(black) {
      memset(base, 0, CVPixelBufferGetDataSize(black))
    }
    CVPixelBufferUnlockBaseAddress(black, [])
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault, imageBuffer: black, formatDescriptionOut: &blackFormat)
  }

  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
    ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
  }
}

// MARK: - Streams

/// What apps that use the camera read.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
  private(set) var stream: CMIOExtensionStream!
  private let format: CMIOExtensionStreamFormat
  private unowned let device: CameraDevice

  init(format: CMIOExtensionStreamFormat, device: CameraDevice) {
    self.format = format
    self.device = device
    super.init()
    stream = CMIOExtensionStream(
      localizedName: Camera.name,
      streamID: UUID(uuidString: "A3C4D5E6-1F20-4B3C-8D9E-0A1B2C3D4E5F")!, direction: .source,
      clockType: .hostTime, source: self)
  }

  var formats: [CMIOExtensionStreamFormat] { [format] }

  var activeFormatIndex: Int = 0

  var availableProperties: Set<CMIOExtensionProperty> {
    [.streamActiveFormatIndex, .streamFrameDuration]
  }

  func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
    -> CMIOExtensionStreamProperties
  {
    let result = CMIOExtensionStreamProperties(dictionary: [:])
    if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
    if properties.contains(.streamFrameDuration) { result.frameDuration = Camera.frameDuration }
    return result
  }

  func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

  func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

  func startStream() throws { device.watcherStarted() }

  func stopStream() throws { device.watcherStopped() }
}

/// Where PixelMirror pushes the phone's camera.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
  private(set) var stream: CMIOExtensionStream!
  private let format: CMIOExtensionStreamFormat
  private unowned let device: CameraDevice
  private var client: CMIOExtensionClient?
  private var running = false
  private let queue = DispatchQueue(label: "com.reffwu.pixelmirror.camera.sink")

  init(format: CMIOExtensionStreamFormat, device: CameraDevice) {
    self.format = format
    self.device = device
    super.init()
    stream = CMIOExtensionStream(
      localizedName: "\(Camera.name) Input",
      streamID: UUID(uuidString: "B7E8F9A0-2C31-4D42-9E53-1F2A3B4C5D6E")!, direction: .sink,
      clockType: .hostTime, source: self)
  }

  var formats: [CMIOExtensionStreamFormat] { [format] }

  var activeFormatIndex: Int = 0

  var availableProperties: Set<CMIOExtensionProperty> {
    [
      .streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
      .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
    ]
  }

  func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
    -> CMIOExtensionStreamProperties
  {
    let result = CMIOExtensionStreamProperties(dictionary: [:])
    if properties.contains(.streamActiveFormatIndex) { result.activeFormatIndex = 0 }
    if properties.contains(.streamFrameDuration) { result.frameDuration = Camera.frameDuration }
    if properties.contains(.streamSinkBufferQueueSize) { result.sinkBufferQueueSize = 1 }
    if properties.contains(.streamSinkBuffersRequiredForStartup) {
      result.sinkBuffersRequiredForStartup = 1
    }
    return result
  }

  func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

  func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
    queue.sync { self.client = client }
    return true
  }

  func startStream() throws {
    queue.async {
      self.running = true
      self.consume()
    }
  }

  func stopStream() throws {
    queue.async { self.running = false }
  }

  private func consume() {
    guard running, let client else { return }
    stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
      guard let self else { return }
      self.queue.async {
        guard let buffer else {
          // Nothing queued yet: look again in a frame.
          self.queue.asyncAfter(deadline: .now() + 1.0 / Double(Camera.frameRate)) {
            self.consume()
          }
          return
        }
        self.device.received(buffer)
        self.stream.notifyScheduledOutputChanged(
          CMIOExtensionScheduledOutput(
            sequenceNumber: sequence,
            hostTimeInNanoseconds: UInt64(
              CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))))
        self.consume()
      }
    }
  }
}
