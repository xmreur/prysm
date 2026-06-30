package com.xmreur.prysm

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class BiometricChannelHandler(
    private val activity: FlutterFragmentActivity,
    messenger: BinaryMessenger,
    private val biometricController: BiometricController
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.xmreur.prysm/biometric"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var pendingResult: MethodChannel.Result? = null

    fun register() {
        channel.setMethodCallHandler(this)
    }

    fun unregister() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canAuthenticate" -> {
                result.success(biometricController.canAuthenticate())
            }

            "authenticate" -> {
                if (pendingResult != null) {
                    result.error("ALREADY_ACTIVE", "Authentication already in progress", null)
                    return
                }

                val title = call.argument<String>("title") ?: "Authenticate"
                val subtitle = call.argument<String>("subtitle") ?: ""
                val cancelText = call.argument<String>("cancelText") ?: "Cancel"

                pendingResult = result

                biometricController.authenticate(
                    activity = activity,
                    title = title,
                    subtitle = subtitle,
                    cancelText = cancelText
                ) { payload ->
                    pendingResult?.success(payload)
                    pendingResult = null
                }
            }

            else -> result.notImplemented()
        }
    }
}