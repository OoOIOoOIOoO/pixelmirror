import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MainView: View {
  @ObservedObject var updater: Updater
  @StateObject private var whatsNew = WhatsNewManager.shared
  @ObservedObject private var hub = DeviceHub.shared
  @ObservedObject private var mirrors = MirrorManager.shared
  @ObservedObject private var network = MacNetwork.shared
  @State private var showsPairing = false
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      hero
      VStack(spacing: 16) {
        status
        if hub.known.isEmpty || showsPairing || hub.unpairedPhoneNearby {
          PairingCard()
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        PreferencesCard(updater: updater)
        MoreAppsCard()
      }
      .padding(.horizontal, 20)
      footer
    }
    .frame(width: 440)
    .fixedSize()
    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
    .animation(.smooth(duration: 0.3), value: hub.phones)
    .animation(.smooth(duration: 0.3), value: showsPairing)
    .sheet(isPresented: $whatsNew.isPresented) {
      WhatsNewView { whatsNew.dismiss() }
    }
    .onAppear {
      whatsNew.checkPresentation()
      MoreApps.shared.refreshIfStale()
    }
    .onChange(of: hub.pairing) { _, state in
      if state == .paired {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { showsPairing = false }
      }
    }
  }

  private var hero: some View {
    VStack(spacing: 4) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)
        .padding(.bottom, 10)
      Text(verbatim: AppName.display)
        .font(.system(size: 22, weight: .semibold))
      Text("Your Android phone, live on your Mac.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 38)
    .padding(.bottom, 24)
  }

  // MARK: - Status

  private var status: some View {
    SettingsGroup {
      if hub.phones.isEmpty {
        SettingsRow(
          "antenna.radiowaves.left.and.right", tint: .blue,
          title: searchingTitle,
          subtitle: hub.searchingLong && !hub.known.isEmpty
            ? String(
              localized:
                "Wireless debugging turns off after a restart or a Wi-Fi change. Turn it on again.")
            : String(localized: "Turn on Wireless debugging, or plug it in.")
        ) {
          ProgressView().controlSize(.small)
        }
        checkup
      } else {
        ForEach(Array(hub.phones.enumerated()), id: \.element.id) { index, phone in
          if index > 0 { SettingsDivider() }
          phoneRow(phone)
        }
      }
      if hub.unpairedPhoneNearby {
        SettingsDivider()
        SettingsRow(
          "qrcode", tint: .indigo,
          title: String(localized: "Found a phone that isn't paired"),
          subtitle: String(localized: "Scan the code below with your phone.")
        ) {}
      }
      if hub.needsUSBApproval {
        SettingsDivider()
        SettingsRow(
          "exclamationmark.triangle.fill", tint: .orange,
          title: String(localized: "Allow USB debugging on your phone"),
          subtitle: String(localized: "Tap Allow, and tick Always allow from this computer.")
        ) {}
      }
      if !hub.known.isEmpty {
        SettingsDivider()
        SettingsRow(
          "qrcode", tint: .indigo, title: String(localized: "Pair a new phone")
        ) {
          Button(showsPairing ? String(localized: "Done") : String(localized: "Pair…")) {
            showsPairing.toggle()
            if showsPairing { hub.resetPairing() }
          }
          .controlSize(.small)
        }
      }
    }
  }

  /// Why nothing turns up, most likely cause first. Only one row: the one to fix now.
  @ViewBuilder private var checkup: some View {
    if network.localNetworkDenied {
      SettingsDivider()
      SettingsRow(
        "hand.raised.fill", tint: .orange,
        title: String(localized: "Local network access is off"),
        subtitle: String(localized: "Turn it on for this app in Privacy & Security.")
      ) {
        Button(String(localized: "Open Settings")) { network.openLocalNetworkSettings() }
          .controlSize(.small)
      }
    } else if network.offline {
      SettingsDivider()
      SettingsRow(
        "wifi.slash", tint: .orange,
        title: String(localized: "Your Mac is offline"),
        subtitle: String(localized: "Join the Wi-Fi your phone is on.")
      ) {}
    } else if network.vpn {
      SettingsDivider()
      SettingsRow(
        "lock.fill", tint: .orange,
        title: String(localized: "A VPN is on"),
        subtitle: String(localized: "It can hide your phone. Turn it off to connect.")
      ) {}
    } else if hub.phoneUnreachable {
      SettingsDivider()
      SettingsRow(
        "wifi.exclamationmark", tint: .orange,
        title: String(localized: "Your phone can't be reached"),
        subtitle: String(
          localized: "Your router may keep devices apart. Try another Wi-Fi, or a cable.")
      ) {}
    }
  }

  private var searchingTitle: String {
    if let phone = hub.known.last {
      return String(localized: "Looking for \(phone.name)…")
    }
    return String(localized: "Looking for your phone…")
  }

  private func phoneRow(_ phone: Phone) -> some View {
    let via = phone.isUSB ? String(localized: "USB") : String(localized: "Wi-Fi")
    let subtitle = phone.android.isEmpty ? via : "\(via) · Android \(phone.android)"
    return SettingsRow(
      phone.isUSB ? "cable.connector" : "wifi", tint: .green, title: phone.name, subtitle: subtitle
    ) {
      let switching = hub.switchingPhoneIDs.contains(phone.id)
      HStack(spacing: 6) {
        Button(
          phone.isUSB ? String(localized: "Switch to Wi-Fi") : String(localized: "Switch to USB")
        ) {
          hub.switchTransport(for: phone)
        }
        .disabled(switching || (!phone.isUSB && !hub.usbPhoneIDs.contains(phone.id)))
        if switching { ProgressView().controlSize(.small) }
        Button(
          mirrors.mirroring.contains(phone.id)
            ? String(localized: "Show") : String(localized: "Mirror")
        ) {
          mirrors.open(phone)
        }
        .disabled(switching)
      }
      .controlSize(.small)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 6) {
      Button {
        openWindow(id: "about")
      } label: {
        Text(verbatim: "\(AppName.display) \(version)")
      }
      .buttonStyle(.plain)
      .help("About PixelMirror")
      Text(verbatim: "·")
      Button("Check for Updates…") { updater.checkForUpdates() }
        .buttonStyle(.plain)
      if let project = URL(string: "https://github.com/ReffWu/pixelmirror") {
        Text(verbatim: "·")
        Link(destination: project) {
          Label("Star on GitHub", systemImage: "star")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
      }
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .padding(.top, 18)
    .padding(.bottom, 20)
  }

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }
}

// MARK: - Pairing

private struct PairingCard: View {
  @ObservedObject private var hub = DeviceHub.shared
  @State private var usesCode = false
  @State private var code = ""

  var body: some View {
    SettingsGroup(
      footnote: String(
        localized:
          "Phone and Mac on the same Wi-Fi. No Developer options? Tap Build number 7 times in Settings › About phone."
      )
    ) {
      HStack(alignment: .top, spacing: 16) {
        QRCodeImage(payload: hub.qr.payload)
          .frame(width: 128, height: 128)
          .opacity(usesCode ? 0.25 : 1)
        VStack(alignment: .leading, spacing: 10) {
          Text("Pair your phone")
            .font(.system(size: 13, weight: .semibold))
          step(1, String(localized: "On your phone, open Developer options › Wireless debugging."))
          if usesCode {
            step(
              2, String(localized: "Tap Pair device with pairing code, then enter the code here."))
            HStack(spacing: 6) {
              TextField("123456", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 90)
                .onSubmit(pair)
              Button("Pair", action: pair)
                .controlSize(.small)
                .disabled(code.filter(\.isNumber).count != 6)
            }
          } else {
            step(2, String(localized: "Tap Pair device with QR code and scan this."))
          }
          Spacer(minLength: 0)
          state
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(14)
    }
  }

  private func step(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(verbatim: "\(number)")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 16, height: 16)
        .background(Circle().fill(Color.accentColor))
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var state: some View {
    switch hub.pairing {
    case .pairing:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text("Pairing…")
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
    case .paired:
      Label("Paired", systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.green)
    case .failed:
      Label("Pairing failed. Try again.", systemImage: "exclamationmark.circle.fill")
        .font(.system(size: 12))
        .foregroundStyle(.orange)
    case .idle:
      Button(
        usesCode ? String(localized: "Use a QR code") : String(localized: "Use a pairing code")
      ) {
        usesCode.toggle()
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
    }
  }

  private func pair() {
    let digits = code.filter(\.isNumber)
    guard digits.count == 6 else { return }
    hub.pair(withCode: digits)
    code = ""
  }
}

private struct QRCodeImage: View {
  let payload: String

  var body: some View {
    Group {
      if let image = Self.render(payload) {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .padding(8)
      }
    }
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
  }

  private static func render(_ payload: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
      let cg = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(
      cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
  }
}
