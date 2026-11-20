import AppKit
import Sparkle
import SwiftUI

@main
struct PixelMirrorApp: App {
  @StateObject private var updater = Updater()

  init() {
    Telemetry.start()
    let hub = DeviceHub.shared
    let mirrors = MirrorManager.shared
    hub.onPhoneReady = { mirrors.phoneBecameReady($0) }
    hub.onPhonesChanged = {
      mirrors.phonesChanged($0)
      Webcam.shared.phonesChanged($0)
    }
    hub.start()
    PhoneNotifications.shared.start()
    StatusMenu.shared.start()
  }

  var body: some Scene {
    Window("PixelMirror", id: "main") {
      MainView(updater: updater)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
    .commands {
      WindowCommands()
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updater.checkForUpdates() }
      }
      PhoneCommands()
    }
    Window("About PixelMirror", id: "about") {
      AboutView()
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentSize)
    .defaultPosition(.center)
  }
}

struct WindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About PixelMirror") {
        openWindow(id: "about")
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      .keyboardShortcut(",")
    }
  }
}

/// The phone's own buttons, for the mirror window in front.
struct PhoneCommands: Commands {
  @ObservedObject private var hub = DeviceHub.shared
  @ObservedObject private var webcam = Webcam.shared
  @ObservedObject private var mirrors = MirrorManager.shared

  var body: some Commands {
    CommandMenu("Phone") {
      Button("Open App…") {
        if let phone = MirrorManager.shared.currentPhone { AppPicker.shared.show(for: phone) }
      }
      .keyboardShortcut("o")
      .disabled(hub.phones.isEmpty)
      Button("Recent Photos") {
        if let phone = MirrorManager.shared.currentPhone {
          RecentPhotosPanel.shared.show(for: phone)
        }
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])
      .disabled(hub.phones.isEmpty)
      if Webcam.canInstall {
        Toggle(
          "Use as Webcam",
          isOn: Binding(
            get: { webcam.phoneID != nil },
            set: { _ in
              if let phone = MirrorManager.shared.currentPhone { Webcam.shared.toggle(phone) }
            })
        )
        .disabled(hub.phones.isEmpty)
      }
      Toggle(
        "Computer Mode",
        isOn: Binding(
          get: { mirrors.currentPhone.map { mirrors.computers.contains($0.id) } ?? false },
          set: { _ in mirrors.toggleComputer() })
      )
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(hub.phones.isEmpty)
      Divider()
      Button("Take Screenshot") { MirrorManager.shared.keyController?.takeScreenshot() }
        .keyboardShortcut("s", modifiers: [.command, .option])
      Button("Record Screen") { MirrorManager.shared.keyController?.toggleRecording() }
        .keyboardShortcut("r", modifiers: [.command, .option])
      Button("Edit Game Keys") { MirrorManager.shared.keyController?.editKeyMap() }
        .keyboardShortcut("k", modifiers: [.command, .option])
      Divider()
      Button("Back") { MirrorManager.shared.keyController?.back() }
        .keyboardShortcut("[")
      Button("Home") { MirrorManager.shared.keyController?.home() }
        .keyboardShortcut("h", modifiers: [.command, .shift])
      Button("Recent Apps") { MirrorManager.shared.keyController?.recents() }
        .keyboardShortcut("s", modifiers: [.command, .shift])
      Button("Notifications") { MirrorManager.shared.keyController?.notifications() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Divider()
      Button("Volume Up") { MirrorManager.shared.keyController?.volumeUp() }
        .keyboardShortcut(.upArrow)
      Button("Volume Down") { MirrorManager.shared.keyController?.volumeDown() }
        .keyboardShortcut(.downArrow)
      Button("Rotate") { MirrorManager.shared.keyController?.rotate() }
        .keyboardShortcut("r")
      Button("Turn Phone Screen On or Off") {
        MirrorManager.shared.keyController?.togglePhoneScreen()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
    }
  }
}

@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
  private var controller: SPUStandardUpdaterController?
  @Published var installsAutomatically = true {
    didSet { controller?.updater.automaticallyDownloadsUpdates = installsAutomatically }
  }

  override init() {
    super.init()
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    controller.updater.automaticallyChecksForUpdates = true
    self.controller = controller
    installsAutomatically = controller.updater.automaticallyDownloadsUpdates
  }

  func checkForUpdates() {
    NSApp.activate(ignoringOtherApps: true)
    controller?.checkForUpdates(nil)
  }

  nonisolated func updater(
    _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock: @escaping () -> Void
  ) -> Bool {
    DispatchQueue.main.async { immediateInstallationBlock() }
    return true
  }
}
