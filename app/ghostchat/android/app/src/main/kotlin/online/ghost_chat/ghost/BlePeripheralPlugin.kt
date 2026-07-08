package online.ghost_chat.ghost

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.Charset
import java.util.*

class BlePeripheralPlugin(
    private val context: Context,
    flutterEngine: FlutterEngine
) {
    companion object {
        private const val TAG = "BlePeripheral"
        private const val METHOD_CHANNEL = "ghostchat/ble_peripheral"
        private const val EVENT_CHANNEL  = "ghostchat/ble_peripheral/events"

        val SERVICE_UUID     = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        val DISCOVERY_UUID   = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567891")
        val MESSAGE_UUID     = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567892")
        val CCCD_UUID        = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
    private val eventChannel  = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
    private var eventSink: EventChannel.EventSink? = null

    private val handler = Handler(Looper.getMainLooper())
    private var bluetoothManager: BluetoothManager? = null
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var isAdvertising = false

    private var discoveryData: ByteArray = ByteArray(0)

    // Connected devices: address -> BluetoothDevice
    private val connectedDevices = mutableMapOf<String, BluetoothDevice>()
    // Subscribed devices for message notifications
    private val subscribedDevices = mutableSetOf<String>()

    // Incoming message buffer (BLE chunks)
    private val incomingBuffers = mutableMapOf<String, StringBuilder>()

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
                "start" -> {
                    val discoveryJson = call.argument<String>("discoveryJson") ?: "{}"
                    discoveryData = discoveryJson.toByteArray(Charset.forName("UTF-8"))
                    startGattServer()
                    startAdvertising()
                    result.success(true)
                }
                "stop" -> {
                    stopAdvertising()
                    stopGattServer()
                    result.success(true)
                }
                "updateDiscovery" -> {
                    val json = call.argument<String>("discoveryJson") ?: "{}"
                    discoveryData = json.toByteArray(Charset.forName("UTF-8"))
                    result.success(true)
                }
                "sendToDevice" -> {
                    val address = call.argument<String>("address") ?: ""
                    val json = call.argument<String>("json") ?: ""
                    sendNotification(address, json)
                    result.success(true)
                }
                "sendToAll" -> {
                    val json = call.argument<String>("json") ?: ""
                    for (addr in subscribedDevices.toList()) {
                        sendNotification(addr, json)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) ==
                    PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
                    PackageManager.PERMISSION_GRANTED
        }
        return true
    }

    private fun startGattServer() {
        if (!hasPermission()) return
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return

        gattServer = bluetoothManager!!.openGattServer(context, gattCallback) ?: return

        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        // Discovery characteristic: readable, contains our profile JSON
        val discoveryChar = BluetoothGattCharacteristic(
            DISCOVERY_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ
        )

        // Message characteristic: writable + notify
        val messageChar = BluetoothGattCharacteristic(
            MESSAGE_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        // CCCD for notifications
        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        messageChar.addDescriptor(cccd)

        service.addCharacteristic(discoveryChar)
        service.addCharacteristic(messageChar)

        gattServer!!.addService(service)
        Log.d(TAG, "GATT server started")
    }

    private fun stopGattServer() {
        if (!hasPermission()) return
        try {
            gattServer?.close()
        } catch (_: Exception) {}
        gattServer = null
        connectedDevices.clear()
        subscribedDevices.clear()
    }

    private fun startAdvertising() {
        if (!hasPermission()) return
        val adapter = bluetoothManager?.adapter ?: return
        advertiser = adapter.bluetoothLeAdvertiser ?: return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0) // advertise indefinitely
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiser!!.startAdvertising(settings, data, advertiseCallback)
    }

    private fun stopAdvertising() {
        if (!hasPermission()) return
        try {
            if (isAdvertising) advertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Exception) {}
        isAdvertising = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            isAdvertising = true
            Log.d(TAG, "BLE advertising started")
            sendEvent(mapOf("event" to "advertising_started"))
        }
        override fun onStartFailure(errorCode: Int) {
            isAdvertising = false
            Log.e(TAG, "BLE advertising failed: $errorCode")
            sendEvent(mapOf("event" to "advertising_failed", "error" to errorCode))
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (!hasPermission()) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevices[device.address] = device
                Log.d(TAG, "Device connected: ${device.address}")
                sendEvent(mapOf("event" to "device_connected", "address" to device.address))
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevices.remove(device.address)
                subscribedDevices.remove(device.address)
                incomingBuffers.remove(device.address)
                Log.d(TAG, "Device disconnected: ${device.address}")
                sendEvent(mapOf("event" to "device_disconnected", "address" to device.address))
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice, requestId: Int, offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (!hasPermission()) return
            if (characteristic.uuid == DISCOVERY_UUID) {
                val slice = if (offset < discoveryData.size) {
                    discoveryData.copyOfRange(offset, discoveryData.size)
                } else {
                    ByteArray(0)
                }
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
            } else {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray?
        ) {
            if (!hasPermission()) return
            if (characteristic.uuid == MESSAGE_UUID && value != null) {
                val json = String(value, Charset.forName("UTF-8"))
                handler.post {
                    sendEvent(mapOf(
                        "event" to "data_received",
                        "address" to device.address,
                        "json" to json
                    ))
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean,
            offset: Int, value: ByteArray?
        ) {
            if (!hasPermission()) return
            if (descriptor.uuid == CCCD_UUID) {
                if (value != null && value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.add(device.address)
                } else {
                    subscribedDevices.remove(device.address)
                }
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }
    }

    private fun sendNotification(address: String, json: String) {
        if (!hasPermission()) return
        val device = connectedDevices[address] ?: return
        val service = gattServer?.getService(SERVICE_UUID) ?: return
        val msgChar = service.getCharacteristic(MESSAGE_UUID) ?: return

        try {
            val bytes = json.toByteArray(Charset.forName("UTF-8"))
            msgChar.value = bytes
            gattServer?.notifyCharacteristicChanged(device, msgChar, false)
        } catch (e: Exception) {
            Log.e(TAG, "sendNotification error: ${e.message}")
        }
    }

    private fun sendEvent(data: Map<String, Any>) {
        handler.post { eventSink?.success(data) }
    }
}
