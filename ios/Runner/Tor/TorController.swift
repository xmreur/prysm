import Darwin
import Foundation
import Tor

actor PrysmTorController {
    static let controlPort: UInt16 = 9051
    static let socksPort: UInt = 9050
    private static let dirPermissions: Int = 0o700
    private static let pendingMarkerName = ".hs_install_pending"
    private static let hsFileNames = [
        "hs_ed25519_secret_key",
        "hs_ed25519_public_key",
        "hostname",
    ]

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
        // A process death mid-install leaves a possibly-mixed HS triplet;
        // purge it before Tor can read the directory.
        repairInterruptedHsInstall()
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

    /// Reads raw hidden-service files as base64 for account transfer, nil when incomplete.
    func getHsKeys() -> [String: String]? {
        let hs = hiddenServiceDirectory
        guard let hostnameData = try? Data(contentsOf: hs.appendingPathComponent("hostname")),
              let hostname = String(data: hostnameData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostname.isEmpty,
              let secret = try? Data(contentsOf: hs.appendingPathComponent("hs_ed25519_secret_key")),
              !secret.isEmpty,
              let publicKey = try? Data(contentsOf: hs.appendingPathComponent("hs_ed25519_public_key")),
              !publicKey.isEmpty else {
            return nil
        }
        return [
            "hostname": hostnameData.base64EncodedString(),
            "hs_ed25519_secret_key": secret.base64EncodedString(),
            "hs_ed25519_public_key": publicKey.base64EncodedString(),
        ]
    }

    /// Writes transferred hidden-service keys. Call while Tor is stopped, before the next start.
    func setHsKeys(_ keys: [String: String]) -> Bool {
        guard let hostnameB64 = keys["hostname"], !hostnameB64.isEmpty,
              let secretB64 = keys["hs_ed25519_secret_key"], !secretB64.isEmpty,
              let publicB64 = keys["hs_ed25519_public_key"], !publicB64.isEmpty,
              let hostnameData = Data(base64Encoded: hostnameB64),
              let hostname = String(data: hostnameData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !hostname.isEmpty,
              let secret = Data(base64Encoded: secretB64),
              !secret.isEmpty,
              let publicKey = Data(base64Encoded: publicB64),
              !publicKey.isEmpty else {
            return false
        }
        do {
            let fm = FileManager.default
            let hs = hiddenServiceDirectory
            try fm.createDirectory(
                at: hs, withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.dirPermissions]
            )
            let secretURL = hs.appendingPathComponent("hs_ed25519_secret_key")
            let publicURL = hs.appendingPathComponent("hs_ed25519_public_key")
            let hostnameURL = hs.appendingPathComponent("hostname")
            let marker = hs.appendingPathComponent(Self.pendingMarkerName)
            // Marker first: a process death mid-write leaves it behind and
            // startTor()'s repair purges the mixed set.
            try Data("installing".utf8).write(to: marker, options: .atomic)
            do {
                try secret.write(to: secretURL, options: .atomic)
                try publicKey.write(to: publicURL, options: .atomic)
                try hostnameData.write(to: hostnameURL, options: .atomic)
            } catch {
                // A mixed key set is worse than none: roll back to no keys
                // so the caller falls back to a fresh onion.
                try? fm.removeItem(at: secretURL)
                try? fm.removeItem(at: publicURL)
                try? fm.removeItem(at: hostnameURL)
                try? fm.removeItem(at: marker)
                throw error
            }
            guard Self.hsTripletPresent(secretURL, publicURL, hostnameURL) else {
                try? fm.removeItem(at: secretURL)
                try? fm.removeItem(at: publicURL)
                try? fm.removeItem(at: hostnameURL)
                try? fm.removeItem(at: marker)
                return false
            }
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: secretURL.path
            )
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: publicURL.path
            )
            try? fm.removeItem(at: marker)
            return true
        } catch {
            NSLog("PrysmTor setHsKeys failed: \(error)")
            return false
        }
    }

    private static func hsTripletPresent(_ urls: URL...) -> Bool {
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size > 0 else {
                return false
            }
        }
        return true
    }

    /// Purges a possibly-mixed HS triplet left by a process death during
    /// setHsKeys(); the next start mints a fresh onion (the user can
    /// restore the backup again). No-op without the marker.
    private func repairInterruptedHsInstall() {
        let fm = FileManager.default
        let hs = hiddenServiceDirectory
        let marker = hs.appendingPathComponent(Self.pendingMarkerName)
        guard fm.fileExists(atPath: marker.path) else { return }
        NSLog("PrysmTor: interrupted HS install detected, purging triplet")
        for name in Self.hsFileNames {
            try? fm.removeItem(at: hs.appendingPathComponent(name))
        }
        try? fm.removeItem(at: marker)
    }

    /// Deletes local hidden-service keys (source deactivation). Next start mints a fresh onion.
    func clearHsKeys() -> Bool {
        do {
            let fm = FileManager.default
            let hs = hiddenServiceDirectory
            if fm.fileExists(atPath: hs.path) {
                try fm.removeItem(at: hs)
            }
            try fm.createDirectory(
                at: hs, withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.dirPermissions]
            )
            let cleared = !fm.fileExists(
                atPath: hs.appendingPathComponent("hs_ed25519_secret_key").path
            ) && !fm.fileExists(
                atPath: hs.appendingPathComponent("hs_ed25519_public_key").path
            ) && !fm.fileExists(
                atPath: hs.appendingPathComponent("hostname").path
            )
            if (!cleared) {
                NSLog("PrysmTor clearHsKeys: key files still present")
                return false
            }
            return true
        } catch {
            NSLog("PrysmTor clearHsKeys failed: \(error)")
            return false
        }
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
