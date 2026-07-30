package com.example.piliplus

import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager.LayoutParams
import com.ryanheise.audioservice.AudioServiceActivity
import android.os.StatFs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val channelName = "piliplus/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageVolumes" -> result.success(getStorageVolumes())
                    else -> result.notImplemented()
                }
            }
    }

    private fun getStorageVolumes(): List<Map<String, Any>> {
        // 列 /storage 下挂载点（MANAGE_EXTERNAL_STORAGE 授权后可访问，跨 API 版本稳定，
        // 避免 StorageManager.getStorageVolumes()(API29+)/getDescription()(API30+) 的版本依赖）
        val results = mutableListOf<Map<String, Any>>()
        val storage = File("/storage")
        if (!storage.exists()) return results
        storage.listFiles()?.forEach { dir ->
            if (!dir.isDirectory) return@forEach
            // /storage/emulated -> 内置存储主用户 /storage/emulated/0
            // /storage/XXXX-XXXX -> 外置 SD 卡
            val actualPath = if (dir.name == "emulated") {
                File("/storage/emulated/0").path
            } else {
                dir.path
            }
            val isRemovable = dir.name != "emulated"
            try {
                val stat = StatFs(actualPath)
                results.add(
                    mapOf(
                        "path" to actualPath,
                        "name" to if (isRemovable) "SD 卡" else "内置存储",
                        "isRemovable" to isRemovable,
                        "totalBytes" to stat.totalBytes,
                        "availableBytes" to stat.availableBytes,
                    ),
                )
            } catch (_: Exception) {}
        }
        return results
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (AndroidHelper.isFoldable) {
            AndroidHelper.ToDart.onConfigurationChanged?.run()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
    }

    override fun onDestroy() {
        stopService(Intent(this, com.ryanheise.audioservice.AudioService::class.java))
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        AndroidHelper.ToDart.onUserLeaveHint?.run()
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        AndroidHelper.isPipMode = isInPictureInPictureMode
    }
}
