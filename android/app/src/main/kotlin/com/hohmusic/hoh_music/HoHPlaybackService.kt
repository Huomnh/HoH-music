package com.hohmusic.hoh_music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 只负责让播放进程拥有 Android 媒体前台服务的生命周期。
 * 音频实例和播放控制仍在 Flutter/media_kit 中，不在这里重复创建播放器。
 */
class HoHPlaybackService : Service() {
    companion object {
        const val ACTION_START = "com.hohmusic.action.START_PLAYBACK"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        private const val CHANNEL_ID = "hoh_music_playback"
        private const val NOTIFICATION_ID = 2301
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "HoH music 播放",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持音乐播放在后台运行"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty().ifEmpty { "HoH music" }
        val artist = intent?.getStringExtra(EXTRA_ARTIST).orEmpty()
        val notificationBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification = notificationBuilder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(artist.ifEmpty { "正在播放" })
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: SecurityException) {
            // 通知权限被拒绝时不阻断 Flutter 前台播放。
            stopSelf()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
