package com.xmreur.prysm

import android.content.*
import android.os.IBinder
import android.util.Log
import IPtProxy.Controller
import kotlinx.coroutines.*
import org.torproject.jni.TorService
import java.io.File
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference

data class TorBridgeConfig(
    val useObfs4: Boolean,
    val bridges: List<String>,
)

class TorController(private val context: Context) {

    private val dataDir: File by lazy { File(context.dataDir, "app_TorService") }
    private val hiddenServiceDir: File by lazy { File(dataDir, "hidden_service") }
    private val iptStateDir: File by lazy { File(dataDir, "ipt_state") }

    private var torServiceConnection: ServiceConnection? = null
    private var torService: TorService? = null
    private var isBound = false
    private var iptProxyController: Controller? = null

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
        if (!iptStateDir.exists()) {
            iptStateDir.mkdirs()
        }
    }

    fun writeTorrc(bridgeConfig: TorBridgeConfig, obfs4SocksPort: Int = 0) {
        val torrcFile = File(dataDir, "torrc")
        val lines = mutableListOf(
            "SocksPort 9050",
            "ControlPort $CONTROL_PORT",
            "DataDirectory ${dataDir.absolutePath}",
            "CookieAuthentication 1",
            "HiddenServiceDir ${hiddenServiceDir.absolutePath}",
            "HiddenServicePort 80 127.0.0.1:12345",
            "Log notice file ${dataDir.absolutePath}/tor.log",
            "SafeLogging 1",
        )

        if (bridgeConfig.useObfs4 && bridgeConfig.bridges.isNotEmpty() && obfs4SocksPort > 0) {
            lines.add("UseBridges 1")
            lines.add("ClientTransportPlugin obfs4 socks5 127.0.0.1:$obfs4SocksPort")
            for (bridge in bridgeConfig.bridges) {
                lines.add("Bridge $bridge")
            }
        }

        val torrcContent = lines.joinToString("\n")
        torrcFile.writeText(torrcContent)
        Log.d("TorController", "Wrote torrc with ${bridgeConfig.bridges.size} bridge(s)")
    }

    suspend fun startTor(bridgeConfig: TorBridgeConfig = TorBridgeConfig(false, emptyList())) {
        val restarting = isBound
        if (restarting) {
            stopTor()
            waitForControlPortClosed()
            delay(RESTART_SETTLE_MS)
        }

        stopObfs4Transport()
        val obfs4Port = if (bridgeConfig.useObfs4 && bridgeConfig.bridges.isNotEmpty()) {
            startObfs4Transport()
        } else {
            0
        }

        writeTorrc(bridgeConfig, obfs4Port)
        val intent = Intent(context, TorService::class.java)

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
            stopObfs4Transport()
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
        stopObfs4Transport()

        latch.complete(Unit)
        stopLatch.set(null)
    }

    private fun startObfs4Transport(): Int {
        val controller = Controller(
            iptStateDir.absolutePath,
            true,
            false,
            "INFO",
            object : IPtProxy.OnTransportEvents {
                override fun connected(name: String?) {}
                override fun error(name: String?, error: Exception?) {}
                override fun stopped(name: String?, error: Exception?) {}
            },
        )
        controller.start(IPtProxy.Obfs4, "")
        val port = controller.port(IPtProxy.Obfs4)
        if (port <= 0) {
            controller.stop(IPtProxy.Obfs4)
            throw IllegalStateException("IPtProxy obfs4 failed to bind a port")
        }
        iptProxyController = controller
        Log.d("TorController", "IPtProxy obfs4 listening on port $port")
        return port
    }

    private fun stopObfs4Transport() {
        iptProxyController?.stop(IPtProxy.Obfs4)
        iptProxyController = null
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
