import AVFoundation
import Combine
import Foundation

/// Applies the same preference to new video layers and to the ones on screen.
@MainActor
final class MirrorCapturePrivacy: ObservableObject {
  static let shared = MirrorCapturePrivacy()

  @Published var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: "mirrorCapturePrivacy")
      for layer in layers.allObjects { layer.preventsCapture = enabled }
    }
  }

  private let defaults: UserDefaults
  private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    enabled = defaults.bool(forKey: "mirrorCapturePrivacy")
  }

  func makeLayer() -> AVSampleBufferDisplayLayer {
    let layer = AVSampleBufferDisplayLayer()
    layer.preventsCapture = enabled
    layers.add(layer)
    return layer
  }
}
