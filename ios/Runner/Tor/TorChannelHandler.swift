import Flutter
import Foundation

final class TorChannelHandler {
    private static let channelName = "prysm_tor"

    private let torController = PrysmTorController()
    private var channel: FlutterMethodChannel?

    static func register(messenger: FlutterBinaryMessenger) {
        let handler = TorChannelHandler()
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        handler.channel = channel
        channel.setMethodCallHandler(handler.handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startTor":
            Task {
                do {
                    let bridgeConfig = Self.parseBridgeConfig(call.arguments)
                    try await torController.startTor(bridgeConfig: bridgeConfig)
                    result(nil)
                } catch {
                    NSLog("TOR startTor failed: \(error)")
                    result(
                        FlutterError(
                            code: "START_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }

        case "stopTor":
            Task {
                do {
                    try await torController.stopTor()
                    result(true)
                } catch {
                    NSLog("TOR stopTor failed: \(error)")
                    result(
                        FlutterError(
                            code: "STOP_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }

        case "restartTor":
            Task {
                do {
                    try await torController.restartTor()
                    result(nil)
                } catch {
                    NSLog("TOR restartTor failed: \(error)")
                    result(
                        FlutterError(
                            code: "RESTART_FAILED",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            }

        case "getCachedOnionAddress":
            Task {
                result(await torController.getCachedOnionAddress())
            }

        case "getOnionAddress":
            Task {
                if let address = await torController.getOnionAddress(),
                   address.hasSuffix(".onion") {
                    result(address)
                } else {
                    result(
                        FlutterError(
                            code: "NO_ADDRESS",
                            message: "ONION address not available",
                            details: nil
                        )
                    )
                }
            }

        case "setCallAudioActive":
            let active = call.arguments as? Bool ?? false
            TorKeepAlive.shared.setCallAudioActive(active)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func parseBridgeConfig(_ arguments: Any?) -> TorBridgeConfig {
        guard let map = arguments as? [String: Any] else {
            return TorBridgeConfig(useObfs4: false, bridges: [])
        }
        let useObfs4 = map["useObfs4"] as? Bool ?? false
        let bridges = map["bridges"] as? [String] ?? []
        return TorBridgeConfig(useObfs4: useObfs4, bridges: bridges)
    }
}
