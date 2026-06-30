package com.xmreur.prysm

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private lateinit var torController: TorController
    private var biometricChannelHandler: BiometricChannelHandler? = null
    private var torChannelHandler: TorChannelHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        torController = TorController(this)

        torChannelHandler = TorChannelHandler(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            torController = torController
        ).also { it.register() }

        biometricChannelHandler = BiometricChannelHandler(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
            biometricController = BiometricController(this)
        ).also { it.register() }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "prysm/flag_secure"
        ).setMethodCallHandler { call, result ->
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        biometricChannelHandler?.unregister()
        biometricChannelHandler = null

        torChannelHandler?.unregister()
        torChannelHandler = null

        super.cleanUpFlutterEngine(flutterEngine)
    }
}