import Foundation
import SwiftUI

/// One phone, however many ways it is attached (a cable and Wi-Fi at once count once).
struct Phone: Identifiable, Equatable {
  var id: String  // hardware serial
  var name: String
  var android: String
  var transport: String  // the adb serial to talk to
  var isUSB: Bool
  var maker: String  // ro.product.manufacturer, for maker-specific advice
}

struct KnownPhone: Codable, Equatable, Identifiable {
  var id: String
  var name: String
  /// Where it last answered over Wi-Fi. Asleep, a phone often stops announcing
  /// itself on the network, but it still answers at this address.
  var address: String?
}

/// Watches USB and the local network all the time, connects every phone it is
/// allowed to, and pairs new ones from a QR code or a pairing code.
@MainActor
final class DeviceHub: ObservableObject {
  static let shared = DeviceHub()

  @Published private(set) var phones: [Phone] = []
  @Published private(set) var usbPhoneIDs: Set<String> = []
  @Published private(set) var switchingPhoneIDs: Set<String> = []
  @Published private(set) var needsUSBApproval = false
  @Published private(set) var known: [KnownPhone] = []
  @Published private(set) var pairing = PairingState.idle
  @Published private(set) var qr = PairingQR.make()
  /// A phone announces Wireless debugging but has never been paired with this Mac.
  @Published private(set) var unpairedPhoneNearby = false
  /// A phone announces Wireless debugging but nothing answers at its address.
  @Published private(set) var phoneUnreachable = false
  /// Nothing has been found for a while, long enough to explain why.
  @Published private(set) var searchingLong = false

  enum PairingState: Equatable {
    case idle, pairing, paired, failed
  }

  /// Called whenever a phone becomes ready, and whenever the set of phones changes.
  var onPhoneReady: ((Phone) -> Void)?
  var onPhonesChanged: (([Phone]) -> Void)?

  private let worker = HubWorker()
  private let queue = DispatchQueue(label: "com.reffwu.pixelmirror.hub")
  private var timer: Timer?
  private var scanning = false
  private var typedCode: String?
  private var pendingSwitches: [Phone] = []
  private var readyIDs: Set<String> = []
  private var searchingSince = Date()

  private init() {
    if let data = UserDefaults.standard.data(forKey: "knownPhones"),
      let list = try? JSONDecoder().decode([KnownPhone].self, from: data)
    {
      known = list
    }
  }

  func start() {
    guard timer == nil else { return }
    scan()
    timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scan() }
    }
  }

  /// Pair with the six-digit code shown under "Pair device with pairing code".
  func pair(withCode code: String) {
    typedCode = code
    pairing = .pairing
    scan()
  }

  func resetPairing() {
    if pairing != .pairing { pairing = .idle }
  }

  func switchTransport(for phone: Phone) {
    guard phones.contains(phone), phone.isUSB || usbPhoneIDs.contains(phone.id),
      switchingPhoneIDs.insert(phone.id).inserted
    else { return }
    pendingSwitches.append(phone)
    scan()
  }

  // MARK: - Scanning

  private func scan() {
    guard !scanning else { return }
    scanning = true
    let request = HubWorker.Request(
      qr: qr, typedCode: typedCode, switches: pendingSwitches,
      lastAddresses: Dictionary(
        known.compactMap { phone in phone.address.map { (phone.id, $0) } },
        uniquingKeysWith: { first, _ in first }))
    pendingSwitches.removeAll()
    queue.async { [worker] in
      let result = worker.scan(request) { started in
        DispatchQueue.main.async { if started { self.pairing = .pairing } }
      }
      DispatchQueue.main.async { self.apply(result, request: request) }
    }
  }

  private func apply(_ result: HubWorker.Result, request: HubWorker.Request) {
    scanning = false
    if let paired = result.paired {
      if request.typedCode != nil, request.typedCode == typedCode { typedCode = nil }
      pairing = paired ? .paired : .failed
      if paired { qr = PairingQR.make() }
    }
    if phones != result.phones {
      phones = result.phones
      onPhonesChanged?(result.phones)
    }
    if usbPhoneIDs != result.usbPhoneIDs { usbPhoneIDs = result.usbPhoneIDs }
    for phone in request.switches { switchingPhoneIDs.remove(phone.id) }
    if needsUSBApproval != result.unauthorized { needsUSBApproval = result.unauthorized }
    if unpairedPhoneNearby != result.unpaired { unpairedPhoneNearby = result.unpaired }
    if phoneUnreachable != result.unreachable { phoneUnreachable = result.unreachable }
    if !result.phones.isEmpty { searchingSince = Date() }
    let long = result.phones.isEmpty && Date().timeIntervalSince(searchingSince) > 12
    if searchingLong != long { searchingLong = long }

    for phone in result.phones where !readyIDs.contains(phone.id) {
      remember(phone, address: result.addresses[phone.id])
      onPhoneReady?(phone)
    }
    for phone in result.phones {
      if let address = result.addresses[phone.id],
        known.first(where: { $0.id == phone.id })?.address != address
      {
        remember(phone, address: address)
      }
    }
    readyIDs = Set(result.phones.map(\.id))
    if !pendingSwitches.isEmpty { scan() }
  }

  private func remember(_ phone: Phone, address: String?) {
    let entry = KnownPhone(
      id: phone.id, name: phone.name,
      address: address ?? known.first { $0.id == phone.id }?.address)
    if let index = known.firstIndex(where: { $0.id == phone.id }) {
      guard known[index] != entry else { return }
      known[index] = entry
    } else {
      known.append(entry)
    }
    if let data = try? JSONEncoder().encode(known) {
      UserDefaults.standard.set(data, forKey: "knownPhones")
    }
  }
}

/// The part of the hub that talks to adb. Only ever used on the hub's queue.
final class HubWorker: @unchecked Sendable {
  struct Request {
    var qr: PairingQR
    var typedCode: String?
    var switches: [Phone]
    var lastAddresses: [String: String]  // known phone id → its last Wi-Fi address
  }

  struct Result {
    var phones: [Phone] = []
    var usbPhoneIDs: Set<String> = []
    var addresses: [String: String] = [:]  // phone id → Wi-Fi address
    var unauthorized = false
    var unpaired = false
    var unreachable = false
    var paired: Bool?
  }

  private struct Identity {
    var id: String
    var name: String
    var android: String
    var maker: String
  }

  private var identities: [String: Identity] = [:]
  private var lastAttempt: [String: Date] = [:]
  private var failures: [String: ADB.Connection] = [:]  // announced address → why it failed
  private var preferWiFi: Set<String> = []
  private var directAddresses: [String: String] = [:]
  private var enabledTCP: Set<String> = []
  private var started = false

  func scan(_ request: Request, pairingStarted: (Bool) -> Void) -> Result {
    if !started {
      ADB.run(["start-server"], timeout: 15)
      started = true
    }
    var result = Result()
    let services = ADB.services()
    for phone in request.switches { switchTransport(for: phone, services: services) }

    // Pairing: the phone advertises a pairing service named after our QR code,
    // or a pairing service of its own while someone types its pairing code.
    let pairingServices = services.filter { $0.type.hasPrefix("_adb-tls-pairing") }
    if let service = pairingServices.first(where: { $0.name == request.qr.name }) {
      pairingStarted(true)
      result.paired = ADB.pair(service.address, code: request.qr.password)
    } else if let code = request.typedCode, let service = pairingServices.first {
      result.paired = ADB.pair(service.address, code: code)
    }

    // Connect every phone that offers wireless debugging and is not attached yet.
    var devices = ADB.devices()
    // A Wi-Fi attachment that went offline rarely recovers by itself: drop it so it can be dialled again.
    let stale = devices.filter { !$0.isUSB && $0.state == "offline" }
    if !stale.isEmpty {
      for device in stale { ADB.disconnect(device.serial) }
      devices = ADB.devices()
    }
    let attachedIDs = Set(devices.compactMap { identities[$0.serial]?.id ?? impliedID(of: $0) })
    let attachedSerials = Set(devices.map(\.serial))
    var connected = false
    let announced = services.filter { $0.type.hasPrefix("_adb-tls-connect") }
    failures = failures.filter { address, _ in announced.contains { $0.address == address } }
    for service in announced {
      if attachedSerials.contains(service.address) { continue }
      if let id = ADB.serial(fromServiceName: service.name), attachedIDs.contains(id) { continue }
      if let last = lastAttempt[service.address], Date().timeIntervalSince(last) < 4 { continue }
      lastAttempt[service.address] = Date()
      let outcome = ADB.connect(service.address)
      if outcome == .connected { connected = true }
      failures[service.address] = outcome == .connected ? nil : outcome
    }
    // A known phone that has gone quiet on the network may still be at its last address.
    for (id, address) in request.lastAddresses where !attachedIDs.contains(id) {
      if attachedSerials.contains(address) || announced.contains(where: { $0.address == address }) {
        continue
      }
      if let last = lastAttempt[address], Date().timeIntervalSince(last) < 10 { continue }
      lastAttempt[address] = Date()
      if ADB.connect(address) == .connected { connected = true }
    }
    for (id, address) in directAddresses where preferWiFi.contains(id) {
      guard !attachedSerials.contains(address) else { continue }
      if let last = lastAttempt[address], Date().timeIntervalSince(last) < 4 { continue }
      lastAttempt[address] = Date()
      if connect(address, to: id) { connected = true }
    }
    result.unpaired = failures.values.contains(.needsPairing)
    result.unreachable = failures.values.contains(.unreachable)
    if connected || result.paired == true { devices = ADB.devices() }

    // Learn who each attachment is, once per attachment.
    let present = Set(devices.map(\.serial))
    identities = identities.filter { present.contains($0.key) }
    for device in devices where device.state == "device" && identities[device.serial] == nil {
      identities[device.serial] = identify(device)
    }

    var byID: [String: Phone] = [:]
    for device in devices where device.state == "device" {
      guard let identity = identities[device.serial] else { continue }
      if device.isUSB { result.usbPhoneIDs.insert(identity.id) }
      let wantsUSB = !preferWiFi.contains(identity.id)
      if byID[identity.id]?.isUSB == wantsUSB { continue }
      byID[identity.id] = Phone(
        id: identity.id, name: identity.name, android: identity.android,
        transport: device.serial, isUSB: device.isUSB, maker: identity.maker)
    }
    for device in devices where !device.isUSB && device.state == "device" {
      guard let id = identities[device.serial]?.id else { continue }
      if device.serial == directAddresses[id] { continue }
      if device.serial.contains(":") {
        result.addresses[id] = device.serial
      } else if let service = announced.first(where: { device.serial.hasPrefix($0.name) }) {
        result.addresses[id] = service.address
      }
    }
    result.phones = byID.values.sorted { $0.name < $1.name }
    result.unauthorized = devices.contains { $0.isUSB && $0.state == "unauthorized" }
    return result
  }

  private func switchTransport(for phone: Phone, services: [ADB.Service]) {
    let devices = ADB.devices().filter { $0.state == "device" }
    guard let usb = devices.first(where: {
      $0.isUSB && (identities[$0.serial]?.id ?? $0.serial) == phone.id
    }) else { return }
    if phone.isUSB {
      let alreadyConnected = devices.contains {
        !$0.isUSB && ADB.shell($0.serial, "getprop ro.serialno") == phone.id
      }
      let pairedService = services.first {
        $0.type.hasPrefix("_adb-tls-connect") && ADB.serial(fromServiceName: $0.name) == phone.id
      }
      if alreadyConnected || pairedService.map({ connect($0.address, to: phone.id) }) == true {
        preferWiFi.insert(phone.id)
      } else if let address = openDirectWiFi(usb: usb.serial, phoneID: phone.id) {
        directAddresses[phone.id] = address
        preferWiFi.insert(phone.id)
      }
    } else {
      if enabledTCP.contains(phone.id) {
        guard restoreUSB(usb.serial) else { return }
        enabledTCP.remove(phone.id)
      }
      if let address = directAddresses.removeValue(forKey: phone.id) { ADB.disconnect(address) }
      preferWiFi.remove(phone.id)
    }
  }

  private func openDirectWiFi(usb serial: String, phoneID: String) -> String? {
    guard ADB.shell(serial, "getprop ro.adb.secure") == "1",
      ADB.shell(serial, "getprop ro.serialno") == phoneID
    else { return nil }
    let interfaces = ADB.shell(serial, "ip -4 -o addr show dev wlan0 scope global")
    guard let range = interfaces.range(
      of: #"\binet ([0-9]{1,3}\.){3}[0-9]{1,3}/"#, options: .regularExpression)
    else { return nil }
    let ip = interfaces[range].dropFirst("inet ".count).dropLast()
    let servicePort = ADB.shell(serial, "getprop service.adb.tcp.port")
    let currentPort = UInt16(
      servicePort.isEmpty ? ADB.shell(serial, "getprop persist.adb.tcp.port") : servicePort) ?? 0
    let port = currentPort == 0 ? 5555 : currentPort
    let address = "\(ip):\(port)"
    let needsTCP = currentPort == 0
    if needsTCP {
      guard ADB.run(["-s", serial, "tcpip", String(port)], timeout: 5).ok else { return nil }
      enabledTCP.insert(phoneID)
    }
    for attempt in 0..<3 {
      if attempt > 0 { Thread.sleep(forTimeInterval: 0.7) }
      if connect(address, to: phoneID) { return address }
    }
    if needsTCP, restoreUSB(serial) { enabledTCP.remove(phoneID) }
    return nil
  }

  private func connect(_ address: String, to id: String) -> Bool {
    guard ADB.connect(address) == .connected else { return false }
    if ADB.shell(address, "getprop ro.serialno", timeout: 3) == id { return true }
    ADB.disconnect(address)
    return false
  }

  private func restoreUSB(_ serial: String) -> Bool {
    for _ in 0..<3 {
      let result = ADB.run(["-s", serial, "usb"], timeout: 3)
      if result.ok, result.output.contains("restarting in USB mode") {
        _ = ADB.run(["-s", serial, "wait-for-device"], timeout: 6)
        return true
      }
      Thread.sleep(forTimeInterval: 0.5)
    }
    return false
  }

  /// A cable's serial is the hardware serial; adb's own mDNS connections carry it in the name.
  private func impliedID(of device: ADB.Device) -> String? {
    if device.isUSB { return device.serial }
    if device.serial.hasPrefix("adb-"), let name = device.serial.split(separator: ".").first {
      return ADB.serial(fromServiceName: String(name))
    }
    return nil
  }

  private func identify(_ device: ADB.Device) -> Identity {
    // On a cable, also switch Wireless debugging on, so unplugging keeps the phone here.
    let enableWireless =
      device.isUSB
      ? "; [ \"$(settings get global adb_wifi_enabled)\" = 1 ] || settings put global adb_wifi_enabled 1"
      : ""
    let lines = ADB.shell(
      device.serial,
      "getprop ro.serialno; settings get global device_name; getprop ro.build.version.release; "
        + "getprop ro.product.manufacturer" + enableWireless
    )
    .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let serial = lines.first ?? ""
    var name = lines.count > 1 ? lines[1] : ""
    if name.isEmpty || name == "null" { name = device.model.isEmpty ? "Android" : device.model }
    return Identity(
      id: serial.isEmpty ? device.serial : serial, name: name,
      android: lines.count > 2 ? lines[2] : "", maker: lines.count > 3 ? lines[3] : "")
  }
}

/// The QR code Android's "Pair device with QR code" scanner understands.
struct PairingQR: Equatable {
  var name: String
  var password: String

  var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

  static func make() -> PairingQR {
    let letters = Array("abcdefghijkmnpqrstuvwxyz23456789")
    func random(_ count: Int) -> String {
      String((0..<count).map { _ in letters.randomElement()! })
    }
    return PairingQR(name: "pixelmirror-\(random(6))", password: random(10))
  }
}
