package com.xmreur.prysm

import android.content.*
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.*
import org.torproject.jni.TorService
import java.io.File
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference

class TorController(private val context: Context) {

    private val dataDir: File by lazy { File(context.dataDir, "app_TorService") }
    private val hiddenServiceDir: File by lazy { File(dataDir, "hidden_service") }

    private var torServiceConnection: ServiceConnection? = null
    private var torService: TorService? = null
    private var isBound = false

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val stopLatch = AtomicReference<CompletableDeferred<Unit>?>(null)

    companion object {
        private const val CONTROL_PORT = 9051
        private const val STOP_SETTLE_MS = 500L
        private const val RESTART_SETTLE_MS = 800L
        private const val PORT_POLL_MS = 100L
        private const val PORT_POLL_TIMEOUT_MS = 3000L
    }

    init {
        if (!dataDir.exists()) {
            val created = dataDir.mkdirs()
            Log.d("TorController", "dataDir created: $created at ${dataDir.absolutePath}")
        }
        if (!hiddenServiceDir.exists()) {
            val created = hiddenServiceDir.mkdirs()
            Log.d("TorController", "hiddenServiceDir created: $created at ${hiddenServiceDir.absolutePath}")
        }
    }

    fun writeTorrc() {
        val torrcFile = File(dataDir, "torrc")
        val torrcContent = """
            SocksPort 9050
            ControlPort $CONTROL_PORT
            DataDirectory ${dataDir.absolutePath}
            CookieAuthentication 1
            HiddenServiceDir ${hiddenServiceDir.absolutePath}
            HiddenServicePort 80 127.0.0.1:12345
            Log notice file ${dataDir.absolutePath}/tor.log
            SafeLogging 1
        """.trimIndent()

        torrcFile.writeText(torrcContent)
        Log.d("TorController", "Wrote torrc:\n$torrcContent")
    }

    suspend fun startTor() {
        val restarting = isBound
        if (restarting) {
            stopTor()
            waitForControlPortClosed()
            delay(RESTART_SETTLE_MS)
        }

        writeTorrc()
        val intent = Intent(context, TorService::class.java)

        // TorService from tor-android enters the foreground via bindService
        // (BIND_AUTO_CREATE). Do NOT call startForegroundService here — on
        // restart Android kills the app if startForeground() is not called in
        // time, and TorService only promotes itself when bound.

        val connected = CompletableDeferred<Unit>()

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                Log.d("TorController", "TorService connected")
                torService = (binder as TorService.LocalBinder).service
                isBound = true
                connected.complete(Unit)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                Log.d("TorController", "TorService disconnected")
                clearBindingState()
                stopLatch.getAndSet(null)?.complete(Unit)
            }
        }

        torServiceConnection = connection
        val bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        Log.d("TorController", "bindService called, result: $bound")

        if (!bound) {
            clearBindingState()
            throw IllegalStateException("bindService failed")
        }

        withTimeout(60_000) {
            connected.await()
        }

        delay(STOP_SETTLE_MS)
    }

    suspend fun stopTor() {
        val latch = CompletableDeferred<Unit>()
        stopLatch.set(latch)

        torService?.stopSelf()
        torService = null

        unbindSafely()
        waitForControlPortClosed()
        delay(STOP_SETTLE_MS)

        latch.complete(Unit)
        stopLatch.set(null)
    }

    private fun unbindSafely() {
        val connection = torServiceConnection
        if (connection != null && isBound) {
            try {
                context.unbindService(connection)
                Log.d("TorController", "TorService unbound")
            } catch (e: IllegalArgumentException) {
                Log.w("TorController", "unbindService skipped: ${e.message}")
            }
        }
        clearBindingState()
    }

    private fun clearBindingState() {
        torServiceConnection = null
        torService = null
        isBound = false
    }

    private suspend fun waitForControlPortClosed() {
        val deadline = System.currentTimeMillis() + PORT_POLL_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            if (!isControlPortOpen()) return
            delay(PORT_POLL_MS)
        }
        Log.w("TorController", "Control port still open after stop timeout")
    }

    private fun isControlPortOpen(): Boolean {
        return try {
            Socket("127.0.0.1", CONTROL_PORT).use { true }
        } catch (_: Exception) {
            false
        }
    }

    fun getCachedOnionAddress(): String? = readOnionAddressFromFile()

    fun getOnionAddressAsync(onResult: (String?) -> Unit) {
        scope.launch {
            var address: String? = null
            val timeout = 30000L
            val startTime = System.currentTimeMillis()

            while (address == null && System.currentTimeMillis() - startTime < timeout) {
                address = readOnionAddressFromFile()
                if (address == null) {
                    Log.d("TorController", "Onion address not ready yet, retrying...")
                    delay(500)
                }
            }

            withContext(Dispatchers.Main) {
                Log.d("TorController", "Onion address fetch completed with result: $address")
                onResult(address)
            }
        }
    }

    /** Reads raw hidden-service files as base64 for account transfer, null when incomplete. */
    fun getHsKeys(): Map<String, String>? {
        try {
            val hostname = File(hiddenServiceDir, "hostname").takeIf { it.exists() }?.readText() ?: return null
            val secret = File(hiddenServiceDir, "hs_ed25519_secret_key").takeIf { it.exists() }?.readBytes() ?: return null
            val public = File(hiddenServiceDir, "hs_ed25519_public_key").takeIf { it.exists() }?.readBytes() ?: return null
            if (hostname.trim().isEmpty() || secret.isEmpty() || public.isEmpty()) return null
            return mapOf(
                "hostname" to android.util.Base64.encodeToString(hostname.toByteArray(), android.util.Base64.NO_WRAP),
                "hs_ed25519_secret_key" to android.util.Base64.encodeToString(secret, android.util.Base64.NO_WRAP),
                "hs_ed25519_public_key" to android.util.Base64.encodeToString(public, android.util.Base64.NO_WRAP),
            )
        } catch (e: Exception) {
            Log.e("TorController", "Error reading HS keys", e)
            return null
        }
    }

    /** Writes transferred hidden-service keys. Call while Tor is stopped, before the next start. */
    fun setHsKeys(keys: Map<String, String>): Boolean {
        try {
            val hostnameB64 = keys["hostname"] ?: return false
            val secretB64 = keys["hs_ed25519_secret_key"] ?: return false
            val publicB64 = keys["hs_ed25519_public_key"] ?: return false
            val hostname = String(android.util.Base64.decode(hostnameB64, android.util.Base64.NO_WRAP))
            val secret = android.util.Base64.decode(secretB64, android.util.Base64.NO_WRAP)
            val public = android.util.Base64.decode(publicB64, android.util.Base64.NO_WRAP)
            if (hostname.trim().isEmpty() || secret.isEmpty() || public.isEmpty()) return false
            if (!hiddenServiceDir.exists()) hiddenServiceDir.mkdirs()
            File(hiddenServiceDir, "hs_ed25519_secret_key").writeBytes(secret)
            File(hiddenServiceDir, "hs_ed25519_public_key").writeBytes(public)
            File(hiddenServiceDir, "hostname").writeText(hostname)
            return true
        } catch (e: Exception) {
            Log.e("TorController", "Error writing HS keys", e)
            return false
        }
    }

    /** Deletes local hidden-service keys (source deactivation). Next start mints a fresh onion. */
    fun clearHsKeys(): Boolean {
        try {
            if (!hiddenServiceDir.exists()) return true
            hiddenServiceDir.deleteRecursively()
            hiddenServiceDir.mkdirs()
            return true
        } catch (e: Exception) {
            Log.e("TorController", "Error clearing HS keys", e)
            return false
        }
    }

    private fun readOnionAddressFromFile(): String? {
        try {
            val hostnameFile = File(hiddenServiceDir, "hostname")
            if (!hostnameFile.exists()) return null
            val address = hostnameFile.readText().trim()
            Log.d("TorController", "Read onion address: $address")
            return address
        } catch (e: Exception) {
            Log.e("TorController", "Error reading onion address file", e)
            return null
        }
    }
}
