package com.hohmusic.hoh_music

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.widget.RemoteViews

/**
 * Android 媒体前台服务。
 *
 * Flutter/media_kit 仍然拥有真正的音频播放器；本服务只维护 Android
 * MediaSession 和媒体通知，让锁屏、通知栏、耳机按键可以看到并控制当前曲目。
 */
class HoHPlaybackService : Service() {
    companion object {
        const val ACTION_UPDATE = "com.hohmusic.action.UPDATE_PLAYBACK"
        const val ACTION_PLAY = "com.hohmusic.action.PLAY"
        const val ACTION_PAUSE = "com.hohmusic.action.PAUSE"
        const val ACTION_NEXT = "com.hohmusic.action.NEXT"
        const val ACTION_PREVIOUS = "com.hohmusic.action.PREVIOUS"
        const val ACTION_SEEK = "com.hohmusic.action.SEEK"
        const val ACTION_FAVORITE = "com.hohmusic.action.FAVORITE"
        const val ACTION_MEDIA_CONTROL = "com.hohmusic.action.MEDIA_CONTROL"
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        const val EXTRA_ALBUM = "album"
        const val EXTRA_DURATION_MS = "durationMs"
        const val EXTRA_POSITION_MS = "positionMs"
        const val EXTRA_PLAYING = "playing"
        const val EXTRA_ARTWORK = "artwork"
        const val EXTRA_FAVORITE = "favorite"
        const val EXTRA_LYRIC = "lyric"
        const val EXTRA_ACTION = "action"
        private const val CHANNEL_ID = "hoh_music_playback"
        private const val NOTIFICATION_ID = 2301
    }

    private lateinit var mediaSession: MediaSession
    private var title = "HoH music"
    private var artist = ""
    private var album = ""
    private var durationMs = 0L
    private var positionMs = 0L
    private var playing = false
    private var artwork: Bitmap? = null
    private var favorite = false
    private var lyric = ""

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mediaSession = MediaSession(this, "HoH music").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = sendMediaAction("play")

                override fun onPause() = sendMediaAction("pause")

                override fun onSkipToNext() = sendMediaAction("next")

                override fun onSkipToPrevious() = sendMediaAction("previous")

                override fun onSeekTo(pos: Long) {
                    sendMediaAction("seek", pos)
                }

                override fun onCustomAction(action: String, extras: android.os.Bundle?) {
                    if (action == ACTION_FAVORITE) sendMediaAction("favorite")
                }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> sendMediaAction("play")
            ACTION_PAUSE -> sendMediaAction("pause")
            ACTION_NEXT -> sendMediaAction("next")
            ACTION_PREVIOUS -> sendMediaAction("previous")
            ACTION_SEEK -> sendMediaAction(
                "seek",
                intent.getLongExtra(EXTRA_POSITION_MS, positionMs),
            )
            ACTION_FAVORITE -> sendMediaAction("favorite")
            ACTION_UPDATE -> updateFromIntent(intent)
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    private fun updateFromIntent(intent: Intent) {
        if (intent.hasExtra(EXTRA_TITLE)) {
            title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifEmpty { "HoH music" }
        }
        if (intent.hasExtra(EXTRA_ARTIST)) artist = intent.getStringExtra(EXTRA_ARTIST).orEmpty()
        if (intent.hasExtra(EXTRA_ALBUM)) album = intent.getStringExtra(EXTRA_ALBUM).orEmpty()
        if (intent.hasExtra(EXTRA_DURATION_MS)) {
            durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 0L).coerceAtLeast(0L)
        }
        if (intent.hasExtra(EXTRA_POSITION_MS)) {
            positionMs = intent.getLongExtra(EXTRA_POSITION_MS, 0L)
                .coerceIn(0L, durationMs.coerceAtLeast(0L))
        }
        if (intent.hasExtra(EXTRA_PLAYING)) {
            playing = intent.getBooleanExtra(EXTRA_PLAYING, false)
        }
        if (intent.hasExtra(EXTRA_FAVORITE)) {
            favorite = intent.getBooleanExtra(EXTRA_FAVORITE, false)
        }
        if (intent.hasExtra(EXTRA_LYRIC)) lyric = intent.getStringExtra(EXTRA_LYRIC).orEmpty()
        intent.getByteArrayExtra(EXTRA_ARTWORK)?.let { bytes ->
            artwork = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }
        updateMediaSession()
    }

    private fun updateMediaSession() {
        val metadata = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, lyric)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_DESCRIPTION, artist)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
        artwork?.let { bitmap ->
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bitmap)
            metadata.putBitmap(MediaMetadata.METADATA_KEY_ART, bitmap)
            metadata.putBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON, bitmap)
        }
        mediaSession.setMetadata(metadata.build())

        val state = when {
            playing -> PlaybackState.STATE_PLAYING
            durationMs > 0L -> PlaybackState.STATE_PAUSED
            else -> PlaybackState.STATE_NONE
        }
        val actions = PlaybackState.ACTION_PLAY or
            PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or
            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_SKIP_TO_NEXT or
            PlaybackState.ACTION_SEEK_TO
        val playbackState = PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    state,
                    positionMs,
                    if (playing) 1f else 0f,
                    SystemClock.elapsedRealtime(),
                )
                .addCustomAction(
                    PlaybackState.CustomAction.Builder(
                        ACTION_FAVORITE,
                        if (favorite) "取消喜欢" else "加入喜欢",
                        if (favorite) android.R.drawable.btn_star_big_on else android.R.drawable.btn_star_big_off,
                    ).build(),
                )
                .build()
        mediaSession.setPlaybackState(playbackState)
        mediaSession.isActive = true
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val mediaStyle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Notification.DecoratedMediaCustomViewStyle()
        } else {
            Notification.MediaStyle()
        }
        mediaStyle
            .setMediaSession(mediaSession.sessionToken)
            .setShowActionsInCompactView(0, 1, 2)
        return builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(artist.ifEmpty { "正在播放" })
            .setLargeIcon(artwork)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPendingIntent())
            .addAction(action(android.R.drawable.ic_media_previous, "上一首", ACTION_PREVIOUS, 10))
            .addAction(
                action(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (playing) "暂停" else "播放",
                    if (playing) ACTION_PAUSE else ACTION_PLAY,
                    11,
                ),
            )
            .addAction(action(android.R.drawable.ic_media_next, "下一首", ACTION_NEXT, 12))
            .addAction(
                action(
                    if (favorite) android.R.drawable.btn_star_big_on else android.R.drawable.btn_star_big_off,
                    if (favorite) "取消喜欢" else "加入喜欢",
                    ACTION_FAVORITE,
                    13,
                ),
            )
            .setCustomBigContentView(buildExpandedContent())
            .setStyle(mediaStyle)
            .build()
    }

    private fun buildExpandedContent(): RemoteViews {
        val views = RemoteViews(packageName, R.layout.notification_playback)
        views.setTextViewText(R.id.notification_title, title)
        views.setTextViewText(R.id.notification_artist, artist.ifEmpty { "正在播放" })
        views.setTextViewText(R.id.notification_lyric, lyric.ifEmpty { "" })
        artwork?.let { bitmap ->
            views.setImageViewBitmap(R.id.notification_artwork, bitmap)
        }
        views.setImageViewResource(
            R.id.notification_favorite,
            if (favorite) R.drawable.ic_favorite else R.drawable.ic_favorite_border,
        )
        views.setContentDescription(
            R.id.notification_favorite,
            if (favorite) "取消喜欢" else "加入喜欢",
        )
        val favoriteIntent = Intent(this, HoHPlaybackService::class.java)
            .setAction(ACTION_FAVORITE)
        views.setOnClickPendingIntent(
            R.id.notification_favorite,
            PendingIntent.getService(this, 14, favoriteIntent, pendingFlags()),
        )
        return views
    }

    private fun action(
        icon: Int,
        title: String,
        action: String,
        requestCode: Int,
    ): Notification.Action {
        val intent = Intent(this, HoHPlaybackService::class.java).setAction(action)
        val pending = PendingIntent.getService(this, requestCode, intent, pendingFlags())
        return Notification.Action.Builder(icon, title, pending).build()
    }

    private fun contentPendingIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(this, 20, intent, pendingFlags())
    }

    private fun pendingFlags(): Int = PendingIntent.FLAG_UPDATE_CURRENT or
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

    private fun sendMediaAction(action: String, position: Long? = null) {
        val intent = Intent(ACTION_MEDIA_CONTROL).setPackage(packageName)
            .putExtra(EXTRA_ACTION, action)
        if (position != null) intent.putExtra(EXTRA_POSITION_MS, position)
        sendBroadcast(intent)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "HoH music 播放",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "显示锁屏播放控制和歌曲进度"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mediaSession.isActive = false
        mediaSession.release()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
