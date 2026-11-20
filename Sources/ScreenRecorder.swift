import AVFoundation
import AppKit
import CoreMedia

/// Writes the phone's stream to an .mp4 as it arrives: the H.264 video as it is,
/// with no second encode, and the phone's sound encoded to AAC.
final class ScreenRecorder: @unchecked Sendable {
  let url: URL
  private let writer: AVAssetWriter
  private let hasAudio: Bool
  private var video: AVAssetWriterInput?
  private var audio: AVAssetWriterInput?
  private var format: CMFormatDescription?
  private var started = false
  private var pending: CMSampleBuffer?
  private var startTime = CMTime.zero
  private var startClock = Date()
  private var audioFormat: CMAudioFormatDescription?
  private let lock = NSLock()

  init(url: URL, hasAudio: Bool) throws {
    self.url = url
    self.hasAudio = hasAudio
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  }

  /// The video's parameters. Returns false when they change mid-recording (the
  /// phone rotated), since one .mp4 track keeps one size.
  func configure(_ format: CMFormatDescription) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if let current = self.format {
      return CMFormatDescriptionEqual(current, otherFormatDescription: format)
    }
    self.format = format
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    video.expectsMediaDataInRealTime = true
    writer.add(video)
    self.video = video
    if hasAudio {
      let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
        ])
      audio.expectsMediaDataInRealTime = true
      writer.add(audio)
      self.audio = audio
    }
    return writer.startWriting()
  }

  /// The file starts at the first key frame.
  func appendVideo(_ sample: CMSampleBuffer, keyFrame: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard let video, writer.status == .writing else { return }
    if !started {
      guard keyFrame else { return }
      startTime = sample.presentationTimeStamp
      startClock = Date()
      writer.startSession(atSourceTime: startTime)
      started = true
    }
    if !keyFrame,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(
        CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    // Each frame is written once the next arrives, so it lasts until then.
    if let pending { write(pending, until: sample.presentationTimeStamp) }
    pending = sample
  }

  private func write(_ sample: CMSampleBuffer, until end: CMTime) {
    guard let video, video.isReadyForMoreMediaData else { return }
    var timing = CMSampleTimingInfo(
      duration: end - sample.presentationTimeStamp,
      presentationTimeStamp: sample.presentationTimeStamp, decodeTimeStamp: .invalid)
    var timed: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleBufferOut: &timed)
    if let timed { video.append(timed) }
  }

  /// 48 kHz, 16-bit stereo PCM, as the phone sends it.
  func appendAudio(_ pcm: Data, pts: CMTime) {
    lock.lock()
    defer { lock.unlock() }
    guard started, let audio, audio.isReadyForMoreMediaData, let sample = audioSample(pcm, pts)
    else { return }
    audio.append(sample)
  }

  /// Calls back on the main thread with the file, or nil if nothing was recorded.
  func finish(_ done: @escaping (URL?) -> Void) {
    lock.lock()
    let wrote = started
    let writing = writer.status == .writing
    // The phone sends no frames while its screen is still, so the last one lasts until now.
    if wrote, writing {
      let elapsed = CMTime(
        seconds: Date().timeIntervalSince(startClock), preferredTimescale: 1_000_000)
      let end = startTime + elapsed
      if let pending, end > pending.presentationTimeStamp { write(pending, until: end) }
      pending = nil
      writer.endSession(atSourceTime: end)
    }
    video?.markAsFinished()
    audio?.markAsFinished()
    lock.unlock()
    guard wrote, writing else {
      if writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: url)
      DispatchQueue.main.async { done(nil) }
      return
    }
    writer.finishWriting { [writer, url] in
      let ok = writer.status == .completed
      DispatchQueue.main.async { done(ok ? url : nil) }
    }
  }

  private func audioSample(_ pcm: Data, _ pts: CMTime) -> CMSampleBuffer? {
    if audioFormat == nil {
      var description = AudioStreamBasicDescription(
        mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
        mBitsPerChannel: 16, mReserved: 0)
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
    }
    guard let audioFormat, pcm.count >= 4 else { return nil }
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: pcm.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        == noErr, let block
    else { return nil }
    pcm.withUnsafeBytes { bytes in
      _ = CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: pcm.count)
    }
    var sample: CMSampleBuffer?
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts,
      decodeTimeStamp: .invalid)
    var size = 4
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
      sampleCount: pcm.count / 4, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    return sample
  }
}

/// Where screenshots and recordings go, named like the Mac's own.
enum Capture {
  static func fileName(_ title: String, ext: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(
      of: ":", with: "-")
    return "\(safe) \(formatter.string(from: Date())).\(ext)"
  }

  static var desktop: URL {
    FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
  }

  static var movies: URL {
    FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
  }

  static func play(_ name: String) {
    let folder =
      "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    NSSound(contentsOfFile: folder + name, byReference: true)?.play()
  }
}
