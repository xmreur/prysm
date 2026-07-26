import Darwin
import Foundation
import Tor

actor PrysmTorController {
    static let controlPort: UInt16 = 9051
    static let socksPort: UInt = 9050
    private static let dirPermissions: Int = 0o700

    private static let stopSettleMs: UInt64 = 500
    private static let portPollMs: UInt64 = 100

    private var torThread: TorThread?
    private var isRunning = false

    private var dataDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("Tor", isDirectory: true)
    }

    private var cacheDirectory: URL {
        dataDirectory.appendingPathComponent("cache", isDirectory: true)
    }

    private var hiddenServiceDirectory: URL {
        dataDirectory.appendingPathComponent("hidden_service", isDirectory: true)
    }

    private var torrcFile: URL {
        dataDirectory.appendingPathComponent("torrc")
    }

    private var cookieFile: URL {
        dataDirectory.appendingPathComponent("control_auth_cookie")
    }

    private var hostnameFile: URL {
        hiddenServiceDirectory.appendingPathComponent("hostname")
    }

    func startTor() async throws {
        if isRunning, Self.isTcpPortOpen(Self.controlPort) {
            NSLog("PrysmTor: Tor already running")
            return
        }

        if TorThread.active != nil {
            NSLog("PrysmTor: waiting for previous Tor thread to exit before start")
            try await stopTorLocked()
        }

        try await waitForActiveThreadCleared(timeoutSeconds: 60)

        guard TorThread.active == nil else {
            throw NSError(
                domain: "PrysmTor",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: "Previous Tor thread has not exited",
                ]
            )
        }

        try prepareDirectories()
        let torrcPath = try writeTorrc()
        NSLog("PrysmTor: wrote torrc at \(torrcPath.path)")

        let thread = TorThread(arguments: ["-f", torrcPath.path])
        torThread = thread
        thread.start()

        try await waitForTorReady(timeoutSeconds: 120)
        try await Task.sleep(nanoseconds: Self.stopSettleMs * 1_000_000)

        isRunning = true
        TorKeepAlive.shared.start()
        NSLog("PrysmTor: Tor ready on control port \(Self.controlPort)")
    }

    func stopTor() async throws {
        try await stopTorLocked()
    }

    /// Soft restart: keep the TorThread alive and rotate circuits.
    func restartTor() async throws {
        if !isRunning || !Self.isTcpPortOpen(Self.controlPort) {
            try await startTor()
            return
        }

        guard let cookie = try? Data(contentsOf: cookieFile), !cookie.isEmpty else {
            throw NSError(
                domain: "PrysmTor",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Tor cookie missing for restart"]
            )
        }

        await sendSignal(cookie: cookie, signal: "NEWNYM")
        NSLog("PrysmTor: soft restart (NEWNYM) completed")
    }

    func getCachedOnionAddress() -> String? {
        readOnionAddressFromFile()
    }

    func getOnionAddress() async -> String? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let address = readOnionAddressFromFile(),
               address.hasSuffix(".onion") {
                return address
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return readOnionAddressFromFile()
    }

    // MARK: - Private

    private func stopTorLocked() async throws {
        isRunning = false
        TorKeepAlive.shared.stop()

        if let cookie = try? Data(contentsOf: cookieFile), !cookie.isEmpty {
            await sendShutdown(cookie: cookie)
        }

        try await waitForControlPortClosed(timeoutSeconds: 30)
        torThread = nil
        try await waitForActiveThreadCleared(timeoutSeconds: 60)
    }

    private func waitForActiveThreadCleared(timeoutSeconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            torThread = nil
            if TorThread.active == nil {
                return
            }
            if let active = TorThread.active, active.isFinished {
                try await Task.sleep(nanoseconds: 200_000_000)
                if TorThread.active == nil {
                    return
                }
            }
            try await Task.sleep(nanoseconds: Self.portPollMs * 1_000_000)
        }

        NSLog(
            "PrysmTor: TorThread.active still set after \(timeoutSeconds)s " +
                "(finished=\(TorThread.active?.isFinished ?? false))"
        )
        throw NSError(
            domain: "PrysmTor",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "Previous Tor thread did not exit",
            ]
        )
    }

    private func prepareDirectories() throws {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: Self.dirPermissions]

        for url in [dataDirectory, cacheDirectory, hiddenServiceDirectory] {
            if fm.fileExists(atPath: url.path) {
                try fm.setAttributes(attrs, ofItemAtPath: url.path)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
            }
        }
    }

    private func writeTorrc() throws -> URL {
        var lines = [
            "SocksPort \(Self.socksPort)",
            "ControlPort \(Self.controlPort)",
            "DataDirectory \(dataDirectory.path)",
            "CacheDirectory \(cacheDirectory.path)",
            "CookieAuthentication 1",
            "HiddenServiceDir \(hiddenServiceDirectory.path)",
            "HiddenServicePort 80 127.0.0.1:12345",
            "Log notice file \(dataDirectory.path)/tor.log",
            "SafeLogging 1",
        ]

        if let geoBundle = Bundle.geoIp,
           let geoip = geoBundle.geoipFile?.path,
           let geoip6 = geoBundle.geoip6File?.path {
            lines.append("GeoIPFile \(geoip)")
            lines.append("GeoIPv6File \(geoip6)")
        }

        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: torrcFile, atomically: true, encoding: .utf8)
        return torrcFile
    }

    private func readOnionAddressFromFile() -> String? {
        guard let data = try? Data(contentsOf: hostnameFile),
              let address = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else {
            return nil
        }
        return address
    }

    private func sendShutdown(cookie: Data) async {
        await sendSignal(cookie: cookie, signal: "SHUTDOWN")
    }

    private func sendSignal(cookie: Data, signal: String) async {
        let controller = TorController(socketHost: "127.0.0.1", port: Self.controlPort)
        do {
            try controller.connect()
        } catch {
            NSLog("PrysmTor \(signal) connect failed: \(error)")
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.authenticate(with: cookie) { success, error in
                defer {
                    controller.disconnect()
                    continuation.resume()
                }
                guard success else {
                    if let error {
                        NSLog("PrysmTor \(signal) auth failed: \(error)")
                    }
                    return
                }

                controller.sendCommand(
                    "SIGNAL",
                    arguments: [signal],
                    data: nil
                ) { _, _, stop in
                    stop.pointee = true
                    return true
                }
            }
        }
    }

    private func waitForTorReady(timeoutSeconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if Self.isTcpPortOpen(Self.controlPort),
               FileManager.default.fileExists(atPath: cookieFile.path) {
                return
            }
            try await Task.sleep(nanoseconds: Self.portPollMs * 1_000_000)
        }

        let logTail = Self.readLogTail(dataDirectory.appendingPathComponent("tor.log"))
        NSLog("PrysmTor: tor.log tail:\n\(logTail)")
        throw NSError(
            domain: "PrysmTor",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Tor control port or cookie file not ready in time",
            ]
        )
    }

    private func waitForControlPortClosed(timeoutSeconds: UInt64) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if !Self.isTcpPortOpen(Self.controlPort) {
                return
            }
            try await Task.sleep(nanoseconds: Self.portPollMs * 1_000_000)
        }
        NSLog("PrysmTor: control port still open after \(timeoutSeconds)s")
    }

    private static func isTcpPortOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return connected == 0
    }

    private static func readLogTail(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return "(no tor.log yet)"
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(20).joined(separator: "\n")
    }
}
