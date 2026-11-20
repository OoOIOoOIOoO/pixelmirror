import Foundation

/// The bundled adb. Every call has a deadline, so a phone that vanished from
/// the network can never freeze the app the way a bare `adb connect` can.
enum ADB {
  static let executable = Bundle.main.url(forResource: "Helpers/adb", withExtension: nil)!
  static let server = Bundle.main.url(forResource: "Helpers/scrcpy-server", withExtension: nil)!
  static let serverVersion: String = {
    let url = Bundle.main.url(forResource: "Helpers/scrcpy-version", withExtension: "txt")!
    return (try? String(contentsOf: url, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }()

  struct Result {
    var status: Int32
    var output: String
    var ok: Bool { status == 0 }
  }

  /// Runs adb and returns its combined output, or status -1 when the deadline passes.
  @discardableResult
  static func run(_ arguments: [String], timeout: TimeInterval = 10) -> Result {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice

    var data = Data()
    let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      lock.lock()
      data.append(chunk)
      lock.unlock()
    }
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return Result(status: -1, output: error.localizedDescription)
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      _ = done.wait(timeout: .now() + 1)
      pipe.fileHandleForReading.readabilityHandler = nil
      return Result(status: -1, output: "timed out")
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
    lock.lock()
    data.append(rest)
    let output = String(decoding: data, as: UTF8.self)
    lock.unlock()
    return Result(status: process.terminationStatus, output: output)
  }

  /// A long-running adb child, such as the scrcpy server shell.
  static func spawn(_ arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    return process
  }

  private static let environment: [String: String] = {
    var env = ProcessInfo.processInfo.environment
    // Let adb reconnect paired phones on its own as soon as they reappear.
    env["ADB_MDNS_AUTO_CONNECT"] = "adb-tls-connect"
    return env
  }()

  // MARK: - Devices

  struct Device: Hashable {
    var serial: String
    var state: String
    var model: String
    var isUSB: Bool
  }

  static func devices() -> [Device] {
    let result = run(["devices", "-l"], timeout: 5)
    guard result.ok else { return [] }
    return result.output.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
      guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { return nil }
      var model = ""
      var isUSB = false
      for field in parts.dropFirst(2) {
        if field.hasPrefix("model:") {
          model = String(field.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
        }
        if field.hasPrefix("usb:") { isUSB = true }
      }
      return Device(serial: parts[0], state: parts[1], model: model, isUSB: isUSB)
    }
  }

  // MARK: - Wireless debugging

  struct Service: Hashable {
    var name: String
    var type: String
    var address: String
  }

  static func services() -> [Service] {
    let result = run(["mdns", "services"], timeout: 5)
    guard result.ok else { return [] }
    return result.output.split(separator: "\n").compactMap { line in
      let parts = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
      guard parts.count == 3, parts[1].hasPrefix("_adb") else { return nil }
      return Service(name: parts[0], type: parts[1], address: parts[2])
    }
  }

  static func connect(_ address: String) -> Bool {
    let result = run(["connect", address], timeout: 6)
    return result.ok && result.output.contains("connected to")
  }

  static func disconnect(_ address: String) {
    run(["disconnect", address], timeout: 3)
  }

  static func pair(_ address: String, code: String) -> Bool {
    let result = run(["pair", address, code], timeout: 15)
    return result.output.contains("Successfully paired")
  }

  static func shell(_ serial: String, _ command: String, timeout: TimeInterval = 6) -> String {
    run(["-s", serial, "shell", command], timeout: timeout).output
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The serial a wireless debugging service belongs to: `adb-<serial>-<suffix>`.
  static func serial(fromServiceName name: String) -> String? {
    guard name.hasPrefix("adb-") else { return nil }
    let body = name.dropFirst(4)
    guard let dash = body.lastIndex(of: "-") else { return nil }
    return String(body[..<dash])
  }
}

/// The app's name as people see it in Finder: Pixel 镜像 in Chinese, PixelMirror elsewhere.
enum AppName {
  static var display: String {
    Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? "PixelMirror"
  }
}
