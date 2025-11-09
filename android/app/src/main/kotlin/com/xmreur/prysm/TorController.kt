import android.content.*
import android.os.IBinder
import android.util.Log
import kotlinx.coroutines.*
import org.torproject.jni.TorService
import java.io.File

class TorController(private val context: Context) {

    // Fix: Use the same data directory as TorService native layer, matching your app structure.
    // Adjust this path if TorService uses a different one like "app_TorService/data" on your device.
    // Use the actual DataDirectory used by TorService
    private val dataDir: File by lazy { File(context.dataDir, "app_TorService") } // or just context.dataDir
    private val hiddenServiceDir: File by lazy { File(dataDir, "hidden_service") }


    private var torServiceConnection: ServiceConnection? = null
    private var torService: TorService? = null

    private val scope = CoroutineScope(Dispatchers.IO)

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

    // Write a torrc matching the actual data directory with HiddenServiceDir inside it
    fun writeTorrc() {
        val torrcFile = File(dataDir, "torrc")
        val torrcContent = """
            ControlPort 9051
            DataDirectory ${dataDir.absolutePath}
            CookieAuthentication 1
            HiddenServiceDir ${hiddenServiceDir.absolutePath}
            HiddenServicePort 12345 127.0.0.1:12345
            # Enable verbose logs to stdout to debug startup issues
            Log notice stdout
            Log debug stdout
        """.trimIndent()

        torrcFile.writeText(torrcContent)
        Log.d("TorController", "Wrote torrc:\n$torrcContent")
    }

    fun startTor(onStarted: () -> Unit) {
        writeTorrc()
        val intent = Intent(context, TorService::class.java)

        torServiceConnection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                Log.d("TorController", "TorService connected")
                torService = (binder as TorService.LocalBinder).service
                onStarted()
            }
            override fun onServiceDisconnected(name: ComponentName?) {
                Log.d("TorController", "TorService disconnected")
                torService = null
            }
        }

        val bound = context.bindService(intent, torServiceConnection!!, Context.BIND_AUTO_CREATE)
        Log.d("TorController", "bindService called, result: $bound")
    }

    fun stopTor() {
        torService?.stopSelf()
        torServiceConnection?.let {
            context.unbindService(it)
            Log.d("TorController", "TorService unbound")
            torServiceConnection = null
            torService = null
        }
    }

    // Read onion address from the hidden service hostname file in the correct directory
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
