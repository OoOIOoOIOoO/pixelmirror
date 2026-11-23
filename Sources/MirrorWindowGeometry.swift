import AppKit

@MainActor
enum MirrorWindowGeometry {
  static func saveWidth(of window: NSWindow, videoSize: CGSize, phoneID: String) {
    guard videoSize.width > 0, videoSize.height > 0,
      !window.styleMask.contains(.fullScreen), let width = window.contentView?.bounds.width,
      width > 0
    else { return }
    UserDefaults.standard.set(Double(width), forKey: key(videoSize, phoneID: phoneID))
  }

  static func fit(_ window: NSWindow, to size: CGSize, phoneID: String, resize: Bool) {
    guard let screen = window.screen ?? NSScreen.main else { return }
    window.contentAspectRatio = size
    guard resize, !window.styleMask.contains(.fullScreen) else { return }

    let visible = screen.visibleFrame
    let ratio = size.width / size.height
    let saved = UserDefaults.standard.double(forKey: key(size, phoneID: phoneID))
    let width: CGFloat
    if saved.isFinite, saved > 0 {
      let available = window.contentRect(forFrameRect: visible).size
      width = min(CGFloat(saved), available.width, available.height * ratio)
    } else {
      let heightLimit = visible.height * (size.width > size.height ? 0.7 : 0.86)
      let height = min(heightLimit, size.height / screen.backingScaleFactor)
      width = min(height * ratio, visible.width * 0.9)
    }

    let content = NSRect(x: 0, y: 0, width: width, height: width / ratio)
    var frame = window.frameRect(forContentRect: content)
    let old = window.frame
    frame.origin.x = min(max(old.midX - frame.width / 2, visible.minX), visible.maxX - frame.width)
    frame.origin.y = min(max(old.maxY - frame.height, visible.minY), visible.maxY - frame.height)
    window.setFrame(frame, display: true)
  }

  private static func key(_ size: CGSize, phoneID: String) -> String {
    let orientation = size.width > size.height ? "landscape" : "portrait"
    return "mirrorContentWidth.\(phoneID).\(orientation)"
  }
}
