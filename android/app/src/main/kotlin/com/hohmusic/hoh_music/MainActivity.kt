package com.hohmusic.hoh_music

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.hohmusic/foreground_playback"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4201
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        requestNotificationPermissionIfNeeded()
                        val intent = Intent(this, HoHPlaybackService::class.java).apply {
                            action = HoHPlaybackService.ACTION_START
                            putExtra(HoHPlaybackService.EXTRA_TITLE, call.argument<String>("title") ?: "HoH music")
                            putExtra(HoHPlaybackService.EXTRA_ARTIST, call.argument<String>("artist") ?: "")
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("FOREGROUND_SERVICE", error.message, null)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, HoHPlaybackService::class.java))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
        }
    }
}
