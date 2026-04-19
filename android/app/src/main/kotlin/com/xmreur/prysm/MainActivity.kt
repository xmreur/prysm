package com.xmreur.prysm

import TorController
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.torproject.jni.TorService;

class MainActivity : FlutterActivity() {
    private lateinit var torController: TorController

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        torController = TorController(this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "prysm_tor").setMethodCallHandler { call, result ->
            when (call.method) {
                "startTor" -> {
                    torController.startTor {
                        result.success(null)
                    }
                }
                "stopTor" -> {
                    torController.stopTor()
                    result.success(true)
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

        // Screenshot prevention for view-once images
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