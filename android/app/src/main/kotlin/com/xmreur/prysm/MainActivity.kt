package com.xmreur.prysm

import TorController
import android.util.Log
import android.view.WindowManager
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
    private lateinit var torController: TorController

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        torController = TorController(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "prysm_tor").setMethodCallHandler { call, result ->
            when (call.method) {
                "startTor" -> {
                    lifecycleScope.launch {
                        try {
                            torController.startTor()
                            result.success(null)
                        } catch (e: Exception) {
                            Log.e("TOR", "startTor failed", e)
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                }
                "stopTor" -> {
                    lifecycleScope.launch {
                        try {
                            torController.stopTor()
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("TOR", "stopTor failed", e)
                            result.error("STOP_FAILED", e.message, null)
                        }
                    }
                }
                "getOnionAddress" -> {
                    torController.getOnionAddressAsync { onionAddress ->
                        if (onionAddress != null && onionAddress.endsWith(".onion")) {
                            Log.d("TOR", "Onion address ready: $onionAddress")
                            result.success(onionAddress)
                        } else {
                            result.error("NO_ADDRESS", "ONION address not available", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "prysm/flag_secure").setMethodCallHandler { call, result ->
            when (call.method) {
                "enable" -> {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                "disable" -> {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
