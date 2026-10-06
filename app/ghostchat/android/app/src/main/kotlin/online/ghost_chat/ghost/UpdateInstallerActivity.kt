package online.ghost_chat.ghost

import android.app.Activity
import android.os.Bundle
import android.widget.Toast

class UpdateInstallerActivity : Activity() {
    companion object {
        const val PERMISSION_REQUEST = 73143
    }

    private var downloadId: Long = -1L

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        downloadId = intent.getLongExtra(UpdateDownloadSupport.EXTRA_DOWNLOAD_ID, -1L)
        if (downloadId <= 0) {
            finish()
            return
        }
        openOrRequestPermission()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PERMISSION_REQUEST) return
        if (UpdateDownloadSupport.hasInstallPermission(this)) {
            openOrRequestPermission()
        } else {
            Toast.makeText(
                this,
                "Разрешение не включено. Откройте уведомление GhostChat, чтобы повторить установку.",
                Toast.LENGTH_LONG,
            ).show()
            finish()
        }
    }

    private fun openOrRequestPermission() {
        if (!UpdateDownloadSupport.hasInstallPermission(this)) {
            Toast.makeText(
                this,
                "Разрешите GhostChat устанавливать обновления в системных настройках.",
                Toast.LENGTH_LONG,
            ).show()
            UpdateDownloadSupport.requestInstallPermission(this)
            return
        }
        try {
            UpdateDownloadSupport.openInstaller(this, downloadId)
            finish()
        } catch (error: Exception) {
            Toast.makeText(
                this,
                error.message ?: "Не удалось открыть установщик GhostChat",
                Toast.LENGTH_LONG,
            ).show()
            finish()
        }
    }
}
