import AVFoundation
import Foundation

/// Plays the phone's audio (48 kHz, 16-bit stereo PCM) with a small, steady delay:
/// enough to ride out Wi-Fi hiccups, never so much that video and sound drift apart.
final class AudioPlayer: @unchecked Sendable {
  private let engine = AVAudioEngine()
  private var node: AVAudioSourceNode?
  private let lock = NSLock()
  private var ring = [Int16](repeating: 0, count: 48_000 * 2)  // one second, interleaved
  private var readIndex = 0
  private var count = 0  // samples buffered (two per frame)
  private var priming = true

  private let target = 48_000 * 2 * 60 / 1000  // 60 ms before playback starts
  private let ceiling = 48_000 * 2 * 200 / 1000  // above 200 ms, drop back to the target

  func start() {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, buffers in
      let list = UnsafeMutableAudioBufferListPointer(buffers)
      guard list.count == 2,
        let left = list[0].mData?.assumingMemoryBound(to: Float.self),
        let right = list[1].mData?.assumingMemoryBound(to: Float.self)
      else { return noErr }
      self.render(left: left, right: right, frames: Int(frames))
      return noErr
    }
    self.node = node
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try? engine.start()
  }

  func stop() {
    engine.stop()
  }

  func push(_ packet: Data) {
    lock.lock()
    defer { lock.unlock() }
    packet.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      for sample in samples {
        let write = (readIndex + count) % ring.count
        ring[write] = Int16(littleEndian: sample)
        if count < ring.count { count += 1 } else { readIndex = (readIndex + 1) % ring.count }
      }
    }
    if count > ceiling {
      let drop = (count - target) & ~1
      readIndex = (readIndex + drop) % ring.count
      count -= drop
    }
  }

  private func render(
    left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int
  ) {
    lock.lock()
    defer { lock.unlock() }
    if priming, count >= target { priming = false }
    for frame in 0..<frames {
      if priming || count < 2 {
        left[frame] = 0
        right[frame] = 0
        if count < 2 { priming = true }
        continue
      }
      left[frame] = Float(ring[readIndex]) / 32768
      right[frame] = Float(ring[(readIndex + 1) % ring.count]) / 32768
      readIndex = (readIndex + 2) % ring.count
      count -= 2
    }
  }
}
