package com.xmreur.prysm

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity

class BiometricController(
    private val context: Context
) {
    fun canAuthenticate(): Map<String, Any> {
        val biometricManager = BiometricManager.from(context)

        val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.BIOMETRIC_WEAK

        return when (val status = biometricManager.canAuthenticate(authenticators)) {
            BiometricManager.BIOMETRIC_SUCCESS -> mapOf(
                "available" to true,
                "code" to "SUCCESS",
                "message" to "Biometric authentication is available"
            )
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> mapOf(
                "available" to false,
                "code" to "NO_HARDWARE",
                "message" to "No biometric hardware"
            )
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> mapOf(
                "available" to false,
                "code" to "HW_UNAVAILABLE",
                "message" to "Biometric hardware unavailable"
            )
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED-> mapOf(
                "available" to false,
                "code" to "NONE_ENROLLED",
                "message" to "No biometrics enrolled"
            )
            else -> mapOf(
                "available" to false,
                "code" to "UNKNOWN",
                "message" to "Unknown biometric state: $status"
            )
        }
    }

    fun authenticate(
        activity: FlutterFragmentActivity,
        title: String,
        subtitle: String,
        cancelText: String,
        onResult: (Map<String, Any>) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(activity)

        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onResult(
                    mapOf(
                        "success" to true,
                        "code" to "AUTH_SUCCESS"
                    )
                )
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                onResult(
                    mapOf(
                        "success" to false,
                        "code" to mapErrorCode(errorCode),
                        "message" to errString.toString()
                    )
                )
            }

            override fun onAuthenticationFailed() {
            }
        }

        val prompt = BiometricPrompt(activity, executor, callback)

        val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.BIOMETRIC_WEAK

        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText(cancelText)
            .setAllowedAuthenticators(authenticators)
            .build()

        prompt.authenticate(promptInfo)
    }

    private fun mapErrorCode(code: Int): String {
        return when (code) {
            BiometricPrompt.ERROR_HW_NOT_PRESENT -> "HW_NOT_PRESENT"
            BiometricPrompt.ERROR_HW_UNAVAILABLE -> "HW_UNAVAILABLE"
            BiometricPrompt.ERROR_NO_BIOMETRICS -> "NO_BIOMETRICS"
            BiometricPrompt.ERROR_LOCKOUT -> "LOCKOUT"
            BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "LOCKOUT_PERMANENT"
            BiometricPrompt.ERROR_USER_CANCELED -> "USER_CANCELED"
            BiometricPrompt.ERROR_NEGATIVE_BUTTON -> "NEGATIVE_BUTTON"
            BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL -> "NO_DEVICE_CREDENTIAL"
            BiometricPrompt.ERROR_TIMEOUT -> "TIMEOUT"
            else -> "ERROR_$code"
        }
    }
}