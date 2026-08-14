package com.xmreur.prysm

import android.util.Log
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.lifecycleScope
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch

class TorChannelHandler(
    private val activity: FragmentActivity,
    messenger: BinaryMessenger,
    private val torController: TorController
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "prysm_tor")

    fun register() {
        channel.setMethodCallHandler(this)
    }

    fun unregister() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startTor" -> {
                activity.lifecycleScope.launch {
                    try {
                        val bridgeConfig = parseBridgeConfig(call.arguments)
                        torController.startTor(bridgeConfig)
                        result.success(null)
                    } catch (e: Exception) {
                        Log.e("TOR", "startTor failed", e)
                        result.error("START_FAILED", e.message, null)
                    }
                }
            }

            "stopTor" -> {
                activity.lifecycleScope.launch {
                    try {
                        torController.stopTor()
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("TOR", "stopTor failed", e)
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
            }

            "getCachedOnionAddress" -> {
                result.success(torController.getCachedOnionAddress())
            }

            "getOnionAddress" -> {
                torController.getOnionAddressAsync { onionAddress ->
                    if (onionAddress != null && onionAddress.endsWith(".onion")) {
                        result.success(onionAddress)
                    } else {
                        result.error("NO_ADDRESS", "ONION address not available", null)
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun parseBridgeConfig(arguments: Any?): TorBridgeConfig {
        val map = arguments as? Map<*, *> ?: return TorBridgeConfig(false, emptyList())
        val useObfs4 = map["useObfs4"] as? Boolean ?: false
        @Suppress("UNCHECKED_CAST")
        val bridges = map["bridges"] as? List<String> ?: emptyList()
        return TorBridgeConfig(useObfs4, bridges)
    }
}
