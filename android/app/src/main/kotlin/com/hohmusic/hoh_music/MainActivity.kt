package com.hohmusic.hoh_music

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.hohmusic/foreground_playback"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4201
    }

    private var playbackChannel: MethodChannel? = null
    private val mediaReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != HoHPlaybackService.ACTION_MEDIA_CONTROL) return
            val arguments = HashMap<String, Any?>().apply {
                put(HoHPlaybackService.EXTRA_ACTION, intent.getStringExtra(HoHPlaybackService.EXTRA_ACTION))
                if (intent.hasExtra(HoHPlaybackService.EXTRA_POSITION_MS)) {
                    put(
                        HoHPlaybackService.EXTRA_POSITION_MS,
                        intent.getLongExtra(HoHPlaybackService.EXTRA_POSITION_MS, 0L),
                    )
                }
            }
            playbackChannel?.invokeMethod("mediaAction", arguments)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(HoHPlaybackService.ACTION_MEDIA_CONTROL)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(mediaReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(mediaReceiver, filter)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "update" -> {
                            requestNotificationPermissionIfNeeded()
                            val intent = Intent(this, HoHPlaybackService::class.java).apply {
                                action = HoHPlaybackService.ACTION_UPDATE
                                putExtra(
                                    HoHPlaybackService.EXTRA_TITLE,
                                    call.argument<String>(HoHPlaybackService.EXTRA_TITLE) ?: "HoH music",
                                )
                                putExtra(
                                    HoHPlaybackService.EXTRA_ARTIST,
                                    call.argument<String>(HoHPlaybackService.EXTRA_ARTIST) ?: "",
                                )
                                putExtra(
                                    HoHPlaybackService.EXTRA_ALBUM,
                                    call.argument<String>(HoHPlaybackService.EXTRA_ALBUM) ?: "",
                                )
                                call.argument<Number>(HoHPlaybackService.EXTRA_DURATION_MS)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_DURATION_MS, it.toLong())
                                }
                                call.argument<Number>(HoHPlaybackService.EXTRA_POSITION_MS)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_POSITION_MS, it.toLong())
                                }
                                call.argument<Boolean>(HoHPlaybackService.EXTRA_PLAYING)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_PLAYING, it)
                                }
                                call.argument<Boolean>(HoHPlaybackService.EXTRA_FAVORITE)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_FAVORITE, it)
                                }
                                call.argument<String>(HoHPlaybackService.EXTRA_LYRIC)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_LYRIC, it)
                                }
                                call.argument<ByteArray>(HoHPlaybackService.EXTRA_ARTWORK)?.let {
                                    putExtra(HoHPlaybackService.EXTRA_ARTWORK, it)
                                }
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
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
        }
    }

    override fun onDestroy() {
        unregisterReceiver(mediaReceiver)
        playbackChannel = null
        super.onDestroy()
    }
}
