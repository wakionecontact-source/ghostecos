package online.ghost_chat.ghost

import android.app.DownloadManager
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.ContextCompat

internal object UpdateDownloadSupport {
    const val CHANNEL_ID = "ghostchat_update_ready"
    const val EXTRA_DOWNLOAD_ID = "ghostchat_update_download_id"

    private const val PREFS = "ghostchat_update_download_v1"
    private const val PREF_DOWNLOAD_ID = "download_id"
    private const val PREF_VERSION = "version"
    private const val NOTIFICATION_ID = 73142
    private const val MIME_APK = "application/vnd.android.package-archive"

    fun enqueue(context: Context, url: String, version: String): Map<String, Any?> {
        val uri = Uri.parse(url)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank()) {
            "Ссылка на обновление должна использовать HTTPS"
        }
        require(version.matches(Regex("[0-9A-Za-z._+-]{1,32}"))) {
            "Некорректная версия обновления"
        }

        val manager = manager(context)
        val existing = state(context)
        if (existing != null && existing["version"] == version && existing["phase"] != "failed") {
            return existing
        }
        if (existing != null) clear(context, existing["downloadId"] as? Long)

        val fileName = "GhostChat_V${version.replace(Regex("[^0-9A-Za-z._-]"), "_")}ob.apk"
        val request = DownloadManager.Request(uri).apply {
            setTitle("Обновление GhostChat")
            setDescription("Скачиваем версию $version")
            setMimeType(MIME_APK)
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                setAllowedOverMetered(true)
            }
            setAllowedOverRoaming(false)
            setDestinationInExternalFilesDir(
                context,
                Environment.DIRECTORY_DOWNLOADS,
                fileName,
            )
        }
        val id = manager.enqueue(request)
        preferences(context).edit()
            .putLong(PREF_DOWNLOAD_ID, id)
            .putString(PREF_VERSION, version)
            .apply()
        return state(context) ?: mapOf(
            "downloadId" to id,
            "version" to version,
            "phase" to "downloading",
            "progress" to null,
            "message" to null,
        )
    }

    fun state(context: Context): Map<String, Any?>? {
        val prefs = preferences(context)
        val id = prefs.getLong(PREF_DOWNLOAD_ID, -1L)
        val version = prefs.getString(PREF_VERSION, null)?.trim().orEmpty()
        if (id <= 0 || version.isEmpty()) return null

        val cursor = manager(context).query(DownloadManager.Query().setFilterById(id))
        if (cursor == null) {
            return stateMap(id, version, "failed", null, "Загрузка не найдена в Android")
        }
        cursor.use {
            if (!it.moveToFirst()) {
                return stateMap(id, version, "failed", null, "Загрузка не найдена в Android")
            }
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val downloaded = it.getLong(
                it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
            )
            val total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val progress = if (total > 0L) {
                (downloaded.toDouble() / total.toDouble()).coerceIn(0.0, 1.0)
            } else {
                null
            }
            return when (status) {
                DownloadManager.STATUS_PENDING,
                DownloadManager.STATUS_RUNNING,
                DownloadManager.STATUS_PAUSED,
                -> stateMap(id, version, "downloading", progress, null)

                DownloadManager.STATUS_SUCCESSFUL ->
                    stateMap(id, version, "completed", 1.0, null)

                DownloadManager.STATUS_FAILED -> {
                    val reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                    stateMap(id, version, "failed", null, failureMessage(reason))
                }

                else -> stateMap(id, version, "failed", null, "Загрузка была прервана Android")
            }
        }
    }

    fun hasInstallPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    fun requestInstallPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val settings = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${activity.packageName}"),
            )
            activity.startActivityForResult(settings, UpdateInstallerActivity.PERMISSION_REQUEST)
        }
    }

    fun openInstaller(activity: Activity, id: Long) {
        if (!hasInstallPermission(activity)) {
            requestInstallPermission(activity)
            throw IllegalStateException(
                "Разрешите GhostChat устанавливать APK в системных настройках и нажмите «Установить» ещё раз",
            )
        }

        val uri = manager(activity).getUriForDownloadedFile(id)
            ?: throw IllegalStateException("Скачанный APK не найден")
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, MIME_APK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(intent)
        notificationManager(activity).cancel(NOTIFICATION_ID)
    }

    fun clear(context: Context, requestedId: Long? = null) {
        val prefs = preferences(context)
        val storedId = prefs.getLong(PREF_DOWNLOAD_ID, -1L)
        if (storedId > 0 && (requestedId == null || requestedId == storedId)) {
            manager(context).remove(storedId)
            prefs.edit().remove(PREF_DOWNLOAD_ID).remove(PREF_VERSION).apply()
            notificationManager(context).cancel(NOTIFICATION_ID)
        }
    }

    fun showCompletedNotification(context: Context, id: Long, version: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        val openIntent = Intent(context, UpdateInstallerActivity::class.java).apply {
            putExtra(EXTRA_DOWNLOAD_ID, id)
        }
        val pending = PendingIntent.getActivity(
            context,
            id.toInt(),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("Обновление GhostChat скачано")
            .setContentText("Нажмите, чтобы открыть системный установщик")
            .setSubText("Версия $version")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .build()
        notificationManager(context).notify(NOTIFICATION_ID, notification)
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Обновления GhostChat",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Готовность скачанного обновления GhostChat к установке"
        }
        notificationManager(context).createNotificationChannel(channel)
    }

    private fun manager(context: Context) =
        context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    private fun notificationManager(context: Context) =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun preferences(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun stateMap(
        id: Long,
        version: String,
        phase: String,
        progress: Double?,
        message: String?,
    ) = mapOf(
        "downloadId" to id,
        "version" to version,
        "phase" to phase,
        "progress" to progress,
        "message" to message,
    )

    private fun failureMessage(reason: Int): String = when (reason) {
        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "Недостаточно места для обновления"
        DownloadManager.ERROR_DEVICE_NOT_FOUND -> "Не найдено место для сохранения обновления"
        DownloadManager.ERROR_CANNOT_RESUME -> "Не удалось продолжить загрузку"
        DownloadManager.ERROR_HTTP_DATA_ERROR,
        DownloadManager.ERROR_UNHANDLED_HTTP_CODE,
        -> "Сервер прервал загрузку обновления"

        else -> "Загрузка обновления завершилась с ошибкой ($reason)"
    }
}

class UpdateDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val completedId = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
        if (completedId <= 0) return
        val state = UpdateDownloadSupport.state(context) ?: return
        if (state["downloadId"] != completedId || state["phase"] != "completed") return
        val version = state["version"] as? String ?: return
        UpdateDownloadSupport.showCompletedNotification(context, completedId, version)
    }
}
