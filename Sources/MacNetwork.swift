import AppKit
import Network

/// What on the Mac's side can keep a phone out of reach: no network, a VPN that
/// takes over all traffic, or Local Network access turned off for this app.
@MainActor
final class MacNetwork: ObservableObject {
  static let shared = MacNetwork()

  @Published private(set) var offline = false
  @Published private(set) var vpn = false
  @Published private(set) var localNetworkDenied = false

  private let monitor = NWPathMonitor()
  private var browser: NWBrowser?

  private init() {
    monitor.pathUpdateHandler = { path in
      // A full-tunnel VPN puts its own interface first; a split one leaves Wi-Fi first.
      let first = path.availableInterfaces.first?.name ?? ""
      let tunnel = ["utun", "ipsec", "ppp"].contains { first.hasPrefix($0) }
      Task { @MainActor in
        MacNetwork.shared.offline = path.status != .satisfied
        MacNetwork.shared.vpn = path.status == .satisfied && tunnel
      }
    }
    monitor.start(queue: DispatchQueue(label: "com.reffwu.pixelmirror.path"))
    watchLocalNetwork()
  }

  /// Browsing for the phone's own service is what asks for, and reveals, Local Network access.
  private func watchLocalNetwork() {
    let browser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil), using: .tcp)
    browser.stateUpdateHandler = { state in
      var denied = false
      if case .waiting(let error) = state, case .dns(let code) = error,
        code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
      {
        denied = true
      }
      Task { @MainActor in MacNetwork.shared.localNetworkDenied = denied }
    }
    browser.start(queue: DispatchQueue(label: "com.reffwu.pixelmirror.browser"))
    self.browser = browser
  }

  func openLocalNetworkSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
    {
      NSWorkspace.shared.open(url)
    }
  }
}
