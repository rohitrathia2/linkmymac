package com.linkmymac.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import com.linkmymac.android.R
import com.linkmymac.android.ui.MainActivity

/**
 * =============================================================================
 * MediaNotificationHelper: Native Android MediaSession & Notification Controller
 * =============================================================================
 * WHAT IT DOES:
 *   1. Maintains an active Android `MediaSession` representing media currently
 *      playing on the user's Mac (Apple Music, Spotify, YouTube, Podcasts, etc.).
 *   2. Displays an interactive `Notification.MediaStyle` media player in the
 *      Android notification shade, quick settings media carousel, and lock screen.
 *   3. Exposes playback state to `MainActivity` so the companion app can display
 *      live in-app media controls.
 *   4. Dispatches user interaction events (Play, Pause, Next, Prev) back to macOS
 *      via `P2PDaemonService.sendMediaCommand()`.
 *
 * HOW IT DOES IT:
 *   - Configures a low-importance `NotificationChannel` ("linkmymac_media_channel").
 *   - Updates `PlaybackState` (playing vs paused, current elapsed position) and
 *     `MediaMetadata` (title, artist, album, duration).
 *   - Attaches `MediaSession.Callback` for hardware and Bluetooth media keys.
 *   - Generates action PendingIntents targeting `MediaControlReceiver`.
 *
 * WHY IT DOES IT:
 *   Enables full, seamless Continuity-style media control across platforms:
 *   whenever music or video plays on Mac, Android automatically presents
 *   system-native media controls in notifications, lock screen, and the app.
 * =============================================================================
 */
class MediaNotificationHelper(private val context: Context) {

    data class NowPlayingData(
        val hasMedia: Boolean = false,
        val title: String = "",
        val artist: String = "",
        val album: String = "",
        val isPlaying: Boolean = false,
        val duration: Double = 0.0,
        val elapsedTime: Double = 0.0,
        val appName: String = "Mac Media"
    )

    companion object {
        const val CHANNEL_ID = "linkmymac_media_playback_channel"
        const val NOTIFICATION_ID = 8766

        const val ACTION_PLAY_PAUSE = "com.linkmymac.android.ACTION_MEDIA_PLAY_PAUSE"
        const val ACTION_NEXT = "com.linkmymac.android.ACTION_MEDIA_NEXT"
        const val ACTION_PREV = "com.linkmymac.android.ACTION_MEDIA_PREV"
    }

    private val notificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private var mediaSession: MediaSession? = null

    @Volatile
    var currentData = NowPlayingData()
        private set

    /** Observable listener invoked whenever playback state or track metadata changes */
    @Volatile
    var onNowPlayingChanged: ((NowPlayingData) -> Unit)? = null

    init {
        createNotificationChannel()
        initMediaSession()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Mac Now Playing Media",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows active media playback and controls for Mac"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun initMediaSession() {
        try {
            mediaSession = MediaSession(context, "LinkMyMac-MediaSession").apply {
                setCallback(object : MediaSession.Callback() {
                    override fun onPlay() {
                        P2PDaemonService.sendMediaCommand("PLAY")
                    }

                    override fun onPause() {
                        P2PDaemonService.sendMediaCommand("PAUSE")
                    }

                    override fun onSkipToNext() {
                        P2PDaemonService.sendMediaCommand("NEXT_TRACK")
                    }

                    override fun onSkipToPrevious() {
                        P2PDaemonService.sendMediaCommand("PREV_TRACK")
                    }
                })
            }
        } catch (e: Exception) {
            android.util.Log.e("MediaNotificationHelper", "Failed to initialize MediaSession", e)
        }
    }

    /**
     * -------------------------------------------------------------------------
     * updateNowPlaying: Updates Media Session & Notification from Mac State
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Updates track information and posts/dismisses notification.
     * HOW IT DOES IT: Sets MediaMetadata and PlaybackState, builds Notification.MediaStyle.
     * WHY IT DOES IT: Keeps the Android notification panel synchronized with Mac media.
     * -------------------------------------------------------------------------
     */
    fun updateNowPlaying(
        hasMedia: Boolean,
        title: String,
        artist: String,
        album: String,
        isPlaying: Boolean,
        duration: Double,
        elapsedTime: Double,
        appName: String
    ) {
        val updated = NowPlayingData(
            hasMedia = hasMedia,
            title = title,
            artist = artist,
            album = album,
            isPlaying = isPlaying,
            duration = duration,
            elapsedTime = elapsedTime,
            appName = appName
        )
        currentData = updated

        if (!hasMedia || title.isBlank()) {
            // Dismiss media notification and deactivate session
            notificationManager.cancel(NOTIFICATION_ID)
            mediaSession?.isActive = false
            onNowPlayingChanged?.invoke(updated)
            return
        }

        val session = mediaSession
        if (session != null) {
            session.isActive = true

            // 1. Playback State
            val stateActions = PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS

            val state = PlaybackState.Builder()
                .setActions(stateActions)
                .setState(
                    if (isPlaying) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    (elapsedTime * 1000).toLong(),
                    if (isPlaying) 1.0f else 0.0f
                )
                .build()
            session.setPlaybackState(state)

            // 2. Media Metadata
            val meta = MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist.ifEmpty { "Mac Audio" })
                .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, (duration * 1000).toLong())
                .build()
            session.setMetadata(meta)

            // 3. System Notification with MediaStyle
            val contentIntent = PendingIntent.getActivity(
                context,
                100,
                Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val prevIntent = PendingIntent.getBroadcast(
                context,
                101,
                Intent(ACTION_PREV).setPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val playPauseIntent = PendingIntent.getBroadcast(
                context,
                102,
                Intent(ACTION_PLAY_PAUSE).setPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val nextIntent = PendingIntent.getBroadcast(
                context,
                103,
                Intent(ACTION_NEXT).setPackage(context.packageName),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            val playPauseIconRes = if (isPlaying) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            }
            val playPauseTitle = if (isPlaying) "Pause" else "Play"

            val notifBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            notifBuilder
                .setContentTitle(title)
                .setContentText(if (artist.isNotEmpty()) "$artist • Mac" else "Playing on Mac")
                .setSubText("Mac Media")
                .setSmallIcon(R.drawable.app_logo)
                .setContentIntent(contentIntent)
                .setOngoing(isPlaying)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(context, android.R.drawable.ic_media_previous),
                        "Previous",
                        prevIntent
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(context, playPauseIconRes),
                        playPauseTitle,
                        playPauseIntent
                    ).build()
                )
                .addAction(
                    Notification.Action.Builder(
                        Icon.createWithResource(context, android.R.drawable.ic_media_next),
                        "Next",
                        nextIntent
                    ).build()
                )
                .setStyle(
                    Notification.MediaStyle()
                        .setMediaSession(session.sessionToken)
                        .setShowActionsInCompactView(0, 1, 2)
                )

            notificationManager.notify(NOTIFICATION_ID, notifBuilder.build())
        }

        onNowPlayingChanged?.invoke(updated)
    }

    fun teardown() {
        notificationManager.cancel(NOTIFICATION_ID)
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
            mediaSession = null
        } catch (_: Exception) {}
    }
}
