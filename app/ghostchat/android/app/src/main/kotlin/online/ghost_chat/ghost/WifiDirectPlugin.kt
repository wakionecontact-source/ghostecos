package online.ghost_chat.ghost

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.*
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors

class WifiDirectPlugin(
    private val context: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "WifiDirectPlugin"
        private const val METHOD_CHANNEL = "ghostchat/wifi_direct"
        private const val EVENT_CHANNEL  = "ghostchat/wifi_direct/events"
        private const val PORT = 47780
    }

    private val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val eventChannel  = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    private var manager: WifiP2pManager? = null
    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null

    private val handler  = Handler(Looper.getMainLooper())
    private val executor = Executors.newCachedThreadPool()

    private var serverSocket: ServerSocket? = null
    private var isOwner = false
    private var groupOwnerAddress: String? = null

    // Connected peers: deviceAddress -> WifiP2pDevice
    private val connectedPeers = mutableMapOf<String, WifiP2pDevice>()

    fun register() {
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init"       -> { init(); result.success(true) }
                "discover"   -> { discover(); result.success(true) }
                "stop"       -> { stop(); result.success(true) }
                "connect"    -> {
                    val addr = call.argument<String>("deviceAddress") ?: ""
                    connect(addr); result.success(true)
                }
                "send"       -> {
                    val json = call.argument<String>("json") ?: ""
                    val addr = call.argument<String>("address") ?: ""
                    executor.execute { sendData(addr, json) }
                    result.success(true)
                }
                "disconnect" -> { disconnect(); result.success(true) }
                else         -> result.notImplemented()
            }
        }
    }

    private fun init() {
        manager = context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        channel = manager?.initialize(context, Looper.getMainLooper(), null)

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                        if (!hasPermission()) return
                        manager?.requestPeers(channel) { peers ->
                            for (device in peers.deviceList) {
                                sendEvent(mapOf(
                                    "event"         to "peer_found",
                                    "deviceName"    to device.deviceName,
                                    "deviceAddress" to device.deviceAddress,
                                    "status"        to device.status
                                ))
                            }
                        }
                    }
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                        if (!hasPermission()) return
                        manager?.requestConnectionInfo(channel) { info ->
                            if (info.groupFormed) {
                                isOwner = info.isGroupOwner
                                groupOwnerAddress = info.groupOwnerAddress?.hostAddress
                                sendEvent(mapOf(
                                    "event"             to "connected",
                                    "isGroupOwner"      to isOwner,
                                    "groupOwnerAddress" to (groupOwnerAddress ?: "")
                                ))
                                // Start TCP server on group owner
                                if (isOwner) startServer()
                            } else {
                                sendEvent(mapOf("event" to "disconnected"))
                            }
                        }
                    }
                }
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }

        // Always start TCP server to receive data
        startServer()
    }

    private fun discover() {
        if (!hasPermission()) return
        manager?.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                sendEvent(mapOf("event" to "discover_started"))
            }
            override fun onFailure(reason: Int) {
                sendEvent(mapOf("event" to "discover_failed", "reason" to reason))
            }
        })
    }

    private fun connect(deviceAddress: String) {
        if (!hasPermission()) return
        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
        }
        manager?.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Connect initiated to $deviceAddress")
            }
            override fun onFailure(reason: Int) {
                sendEvent(mapOf("event" to "connect_failed", "reason" to reason))
            }
        })
    }

    private fun disconnect() {
        manager?.removeGroup(channel, null)
    }

    private fun stop() {
        try { receiver?.let { context.unregisterReceiver(it) } } catch (_: Exception) {}
        receiver = null
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        manager?.stopPeerDiscovery(channel, null)
    }

    // ── TCP server for receiving data ────────────────────────────────────────

    private fun startServer() {
        if (serverSocket != null && !serverSocket!!.isClosed) return
        executor.execute {
            try {
                serverSocket = ServerSocket(PORT).apply { reuseAddress = true }
                Log.d(TAG, "TCP server listening on $PORT")
                while (!serverSocket!!.isClosed) {
                    try {
                        val client = serverSocket!!.accept()
                        executor.execute { handleClient(client) }
                    } catch (_: Exception) { break }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Server error: ${e.message}")
            }
        }
    }

    private fun handleClient(socket: Socket) {
        try {
            val input = socket.getInputStream().bufferedReader().readText()
            socket.close()
            handler.post {
                sendEvent(mapOf(
                    "event"     to "data_received",
                    "json"      to input,
                    "fromAddress" to socket.inetAddress.hostAddress
                ))
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleClient error: ${e.message}")
            try { socket.close() } catch (_: Exception) {}
        }
    }

    // ── Send data via TCP ────────────────────────────────────────────────────

    private fun sendData(address: String, json: String) {
        try {
            val socket = Socket()
            socket.connect(InetSocketAddress(address, PORT), 5000)
            val writer = socket.getOutputStream().bufferedWriter()
            writer.write(json)
            writer.flush()
            socket.close()
            handler.post {
                sendEvent(mapOf("event" to "data_sent", "address" to address))
            }
        } catch (e: Exception) {
            Log.e(TAG, "sendData error: ${e.message}")
            handler.post {
                sendEvent(mapOf("event" to "send_failed", "address" to address, "error" to (e.message ?: "")))
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return ContextCompat.checkSelfPermission(context, Manifest.permission.NEARBY_WIFI_DEVICES) ==
                    PackageManager.PERMISSION_GRANTED
        }
        return ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun sendEvent(data: Map<String, Any>) {
        handler.post { eventSink?.success(data) }
    }
}
