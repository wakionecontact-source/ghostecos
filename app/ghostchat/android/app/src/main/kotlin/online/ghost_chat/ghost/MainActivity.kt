package online.ghost_chat.ghost

import android.media.AudioManager
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Rect
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import java.io.ByteArrayOutputStream
import java.io.IOException
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private companion object {
        const val PERFORMANCE_CHANNEL = "ghostchat/performance"
        const val LOG_CHANNEL = "ghostchat/logs"
        const val DB_BACKUP_CHANNEL = "ghostchat/db_backup"
        const val SYSTEM_GESTURE_CHANNEL = "ghostchat/system_gesture"
        const val CALL_AUDIO_CHANNEL = "ghostchat/call_audio"
        const val APP_CHANNEL = "ghostchat/app"
        const val APP_AVATAR_COUNT = 20
        const val APP_NAMESPACE = "online.ghost_chat.ghost"
        const val SAVE_LOG_REQUEST_CODE = 7401
        const val SAVE_DB_REQUEST_CODE = 7402
        const val OPEN_DB_REQUEST_CODE = 7403
        const val MAX_DB_BACKUP_BYTES = 256 * 1024 * 1024 + 64
    }

    private var wifiDirectPlugin: WifiDirectPlugin? = null
    private var blePeripheralPlugin: BlePeripheralPlugin? = null
    private var pendingLogResult: MethodChannel.Result? = null
    private var pendingLogContent: ByteArray? = null
    private var pendingDbSaveResult: MethodChannel.Result? = null
    private var pendingDbSaveContent: ByteArray? = null
    private var pendingDbOpenResult: MethodChannel.Result? = null
    private var pendingDeepLink: String? = null
    private var deepLinkChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingDeepLink = intent?.dataString
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = intent.dataString ?: return
        if (deepLinkChannel == null) {
            pendingDeepLink = link
        } else {
            deepLinkChannel?.invokeMethod("onDeepLink", link)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        deepLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ghostchat/deeplink",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        val link = pendingDeepLink
                        pendingDeepLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        wifiDirectPlugin = WifiDirectPlugin(this, flutterEngine)
        wifiDirectPlugin!!.register()

        blePeripheralPlugin = BlePeripheralPlugin(this, flutterEngine)
        blePeripheralPlugin!!.register()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PERFORMANCE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "getState") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val battery = getSystemService(BATTERY_SERVICE) as BatteryManager
            val batteryIntent = registerReceiver(
                null,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED),
            )
            val level = batteryIntent?.getIntExtra(
                BatteryManager.EXTRA_LEVEL,
                battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
            ) ?: battery.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
            val power = getSystemService(POWER_SERVICE) as PowerManager
            val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                power.currentThermalStatus
            } else {
                0
            }
            result.success(
                mapOf(
                    "level" to level,
                    "powerSave" to power.isPowerSaveMode,
                    "thermalStatus" to thermalStatus,
                ),
            )
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOG_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveTextFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (pendingLogResult != null) {
                result.error("save_in_progress", "Сохранение лога уже выполняется", null)
                return@setMethodCallHandler
            }

            val fileName = call.argument<String>("fileName") ?: "ghostchat_log.txt"
            val content = call.argument<String>("content") ?: ""
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "text/plain"
                putExtra(Intent.EXTRA_TITLE, fileName)
            }

            pendingLogResult = result
            pendingLogContent = content.toByteArray(Charsets.UTF_8)
            try {
                startActivityForResult(intent, SAVE_LOG_REQUEST_CODE)
            } catch (error: Exception) {
                pendingLogResult = null
                pendingLogContent = null
                result.error("save_unavailable", error.message, null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DB_BACKUP_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveBackup" -> saveDatabaseBackup(call, result)
                "openBackup" -> openDatabaseBackup(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SYSTEM_GESTURE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "setChatExclusion") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            setChatSystemGestureExclusion(call.arguments as? Boolean == true)
            result.success(null)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CALL_AUDIO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "resetCommunicationAudio") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            resetCommunicationAudio(result)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "restartApp") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val variant = call.argument<Int>("variant")
            if (variant != null) {
                try {
                    applyAppAvatarVariant(variant)
                } catch (error: Exception) {
                    result.error("app_avatar_apply_failed", error.message, null)
                    return@setMethodCallHandler
                }
            }
            restartApplication(result)
        }
    }

    /** Enable one launcher alias so Android shows the selected app avatar. */
    private fun applyAppAvatarVariant(variant: Int) {
        val safeVariant = variant.coerceIn(0, APP_AVATAR_COUNT - 1)
        val packageManager = packageManager
        for (index in 0 until APP_AVATAR_COUNT) {
            val aliasName =
                "$APP_NAMESPACE.AppAvatarAlias${(index + 1).toString().padStart(2, '0')}"
            packageManager.setComponentEnabledSetting(
                ComponentName(packageName, aliasName),
                if (index == safeVariant) {
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                PackageManager.DONT_KILL_APP,
            )
        }
    }

    /** Recreate the Android host so persisted appearance choices are loaded. */
    private fun restartApplication(result: MethodChannel.Result) {
        Handler(Looper.getMainLooper()).post {
            result.success(null)
            recreate()
        }
    }

    /**
     * WebRTC restores its AudioSwitch asynchronously when the last peer
     * connection is disposed. Queue the final reset after that cleanup so the
     * system does not remain in Android's communication volume/mode.
     */
    private fun resetCommunicationAudio(result: MethodChannel.Result) {
        Handler(Looper.getMainLooper()).post {
            try {
                val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    audioManager.clearCommunicationDevice()
                }
                @Suppress("DEPRECATION")
                run {
                    audioManager.isSpeakerphoneOn = false
                    audioManager.mode = AudioManager.MODE_NORMAL
                }
                result.success(null)
            } catch (error: Exception) {
                result.error(
                    "audio_mode_reset_failed",
                    error.message,
                    null,
                )
            }
        }
    }

    /**
     * The chat uses a vertical list. On gesture-navigation devices, a
     * diagonal scroll starting at the display edge can otherwise be consumed
     * by Android as a system Back gesture. Exclude only a narrow edge strip
     * while this route is visible; the hardware Back button is unaffected.
     */
    private fun setChatSystemGestureExclusion(enabled: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return

        val decor = window.decorView
        val width = decor.width
        val height = decor.height
        if (!enabled || width <= 0 || height <= 0) {
            decor.systemGestureExclusionRects = emptyList()
            return
        }

        val edgeWidth = (32 * resources.displayMetrics.density)
            .toInt()
            .coerceAtMost(width / 2)
        if (edgeWidth <= 0) {
            decor.systemGestureExclusionRects = emptyList()
            return
        }
        decor.systemGestureExclusionRects = listOf(
            Rect(0, 0, edgeWidth, height),
            Rect(width - edgeWidth, 0, width, height),
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            SAVE_DB_REQUEST_CODE -> finishDatabaseSave(resultCode, data)
            OPEN_DB_REQUEST_CODE -> finishDatabaseOpen(resultCode, data)
            SAVE_LOG_REQUEST_CODE -> finishLogSave(resultCode, data)
        }
    }

    private fun saveDatabaseBackup(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingDbSaveResult != null || pendingDbOpenResult != null) {
            result.error(
                "backup_picker_in_progress",
                "Выбор файла backup уже выполняется",
                null,
            )
            return
        }
        val content = call.argument<ByteArray>("bytes")
        if (content == null || content.isEmpty()) {
            result.error("invalid_backup", "Пустой backup", null)
            return
        }
        if (content.size > MAX_DB_BACKUP_BYTES) {
            result.error("backup_too_large", "Backup слишком большой", null)
            return
        }
        val requestedName = call.argument<String>("fileName") ?: "ghostchat_database.gcdb"
        val fileName = requestedName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .take(120)
            .ifBlank { "ghostchat_database.gcdb" }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }

        pendingDbSaveResult = result
        pendingDbSaveContent = content
        try {
            startActivityForResult(intent, SAVE_DB_REQUEST_CODE)
        } catch (error: Exception) {
            pendingDbSaveResult = null
            pendingDbSaveContent = null
            result.error("save_unavailable", error.message, null)
        }
    }

    private fun openDatabaseBackup(result: MethodChannel.Result) {
        if (pendingDbSaveResult != null || pendingDbOpenResult != null) {
            result.error(
                "backup_picker_in_progress",
                "Выбор файла backup уже выполняется",
                null,
            )
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/octet-stream", "*/*"))
        }
        pendingDbOpenResult = result
        try {
            startActivityForResult(intent, OPEN_DB_REQUEST_CODE)
        } catch (error: Exception) {
            pendingDbOpenResult = null
            result.error("open_unavailable", error.message, null)
        }
    }

    private fun finishDatabaseSave(resultCode: Int, data: Intent?) {
        val result = pendingDbSaveResult ?: return
        val content = pendingDbSaveContent ?: ByteArray(0)
        pendingDbSaveResult = null
        pendingDbSaveContent = null

        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        try {
            val uri = data.data!!
            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(content)
            } ?: throw IOException("Не удалось открыть файл для записи")
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }

    private fun finishDatabaseOpen(resultCode: Int, data: Intent?) {
        val result = pendingDbOpenResult ?: return
        pendingDbOpenResult = null

        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        try {
            result.success(readDatabaseBackup(data.data!!))
        } catch (error: Exception) {
            result.error("open_failed", error.message, null)
        }
    }

    private fun readDatabaseBackup(uri: android.net.Uri): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        var total = 0
        contentResolver.openInputStream(uri)?.use { input ->
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count == 0) continue
                total += count
                if (total > MAX_DB_BACKUP_BYTES) {
                    throw IOException("Backup слишком большой")
                }
                output.write(buffer, 0, count)
            }
        } ?: throw IOException("Не удалось открыть файл для чтения")
        return output.toByteArray()
    }

    private fun finishLogSave(resultCode: Int, data: Intent?) {
        val result = pendingLogResult ?: return
        val content = pendingLogContent ?: ByteArray(0)
        pendingLogResult = null
        pendingLogContent = null

        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }

        try {
            val uri = data.data!!
            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(content)
            } ?: throw IOException("Не удалось открыть файл для записи")
            result.success(uri.toString())
        } catch (error: Exception) {
            result.error("save_failed", error.message, null)
        }
    }
}
