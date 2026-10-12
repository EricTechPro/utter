package local.utter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import java.io.File

/**
 * Foreground service (type microphone) that keeps a recording alive with the screen off
 * or while you switch apps. The audio itself is recorded by [VoiceDictation]; this only
 * holds the "Recording" notification, whose Stop button ends the recording.
 */
class RecordingService : Service() {
    companion object {
        private const val ACTION_STOP = "local.utter.STOP"
        private const val ACTION_WORKING = "local.utter.WORKING"

        /** Set by the bubble: what the notification's Stop button does. */
        @Volatile var onStopRequested: (() -> Unit)? = null

        fun start(ctx: Context) = send(ctx, null)

        /** Recording ended; show "Transcribing…" until [stop]. */
        fun working(ctx: Context) = send(ctx, ACTION_WORKING)

        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, RecordingService::class.java)) }

        private fun send(ctx: Context, action: String?) {
            try {
                ctx.startService(Intent(ctx, RecordingService::class.java).setAction(action))
            } catch (e: Exception) {
                // Recording still works while the screen is on; it just isn't protected in the background.
                Log.w("Utter", "couldn't start recording service", e)
            }
        }
    }

    private var startedAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { onStopRequested?.invoke(); return START_NOT_STICKY }
            ACTION_WORKING -> { Notify.manager(this).notify(Notify.ID_RECORDING, Notify.recording(this, startedAt, working = true)); return START_NOT_STICKY }
        }
        startedAt = System.currentTimeMillis()
        val n = Notify.recording(this, startedAt, working = false)
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(Notify.ID_RECORDING, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(Notify.ID_RECORDING, n)
            Log.i("Utter", "recording service in foreground")
        } catch (e: Exception) {
            Log.w("Utter", "foreground refused; recording continues without it", e)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        Notify.manager(this).cancel(Notify.ID_RECORDING)
        super.onDestroy()
    }

    internal fun stopIntent(): PendingIntent = PendingIntent.getService(this, 1,
        Intent(this, RecordingService::class.java).setAction(ACTION_STOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
}

/** Notifications and buzzes. */
object Notify {
    const val ID_RECORDING = 1
    // Separate IDs, so a later "Copied" never replaces a "Retry" prompt.
    private const val ID_COPIED = 2
    private const val ID_INTERRUPTED = 3
    private fun failedId(audio: File) = 1000 + (audio.name.hashCode() and 0xFFFF)
    private const val CH_RECORDING = "recording"
    private const val CH_RESULTS = "results"

    fun manager(ctx: Context): NotificationManager {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CH_RECORDING) == null) {
            nm.createNotificationChannel(NotificationChannel(CH_RECORDING, "Recording", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel(CH_RESULTS, "Transcripts", NotificationManager.IMPORTANCE_DEFAULT))
        }
        return nm
    }

    private fun openApp(ctx: Context, retry: File? = null): PendingIntent {
        val i = Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (retry != null) i.putExtra(MainActivity.EXTRA_RETRY, retry.name)
        return PendingIntent.getActivity(ctx, if (retry != null) failedId(retry) else 2, i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun recording(svc: RecordingService, since: Long, working: Boolean): Notification {
        val cap = VoiceDictation.MAX_SECONDS
        manager(svc)
        val b = Notification.Builder(svc, CH_RECORDING)
            .setSmallIcon(R.drawable.ic_wave)
            .setOngoing(true)
            .setContentIntent(openApp(svc))
        if (working) {
            b.setContentTitle("Transcribing…").setContentText("Recording stopped. The words go into the selected text box.")
        } else {
            b.setContentTitle("Utter is recording")
                .setContentText("Stops by itself at ${cap / 60}:${"%02d".format(cap % 60)}.")
                .setUsesChronometer(true).setWhen(since).setShowWhen(true)
                .addAction(Notification.Action.Builder(null, "Stop", svc.stopIntent()).build())
        }
        return b.build()
    }

    fun copied(ctx: Context, text: String) {
        manager(ctx).notify(ID_COPIED, Notification.Builder(ctx, CH_RESULTS)
            .setSmallIcon(R.drawable.ic_wave)
            .setContentTitle("Copied to clipboard")
            .setContentText("No text box was selected. Paste it anywhere; it's also in History.")
            .setStyle(Notification.BigTextStyle().bigText("No text box was selected. Paste it anywhere; it's also in History.\n\n$text"))
            .setContentIntent(openApp(ctx))
            .setAutoCancel(true)
            .build())
    }

    fun failed(ctx: Context, audio: File) {
        manager(ctx).notify(failedId(audio), Notification.Builder(ctx, CH_RESULTS)
            .setSmallIcon(R.drawable.ic_wave)
            .setContentTitle("Couldn't transcribe your recording")
            .setContentText("The audio is saved. Open Utter to retry.")
            .setContentIntent(openApp(ctx, audio))
            .addAction(Notification.Action.Builder(null, "Retry", openApp(ctx, audio)).build())
            .setAutoCancel(true)
            .build())
    }

    /** A recording was cut off (phone restarted, app killed): its audio is safe on disk. */
    fun interrupted(ctx: Context, audio: File, count: Int) {
        val what = if (count == 1) "A recording was interrupted" else "$count recordings were interrupted"
        manager(ctx).notify(ID_INTERRUPTED, Notification.Builder(ctx, CH_RESULTS)
            .setSmallIcon(R.drawable.ic_wave)
            .setContentTitle(what)
            .setContentText("The audio is saved. Open Utter to retry.")
            .setContentIntent(openApp(ctx))
            .addAction(Notification.Action.Builder(null, "Retry", openApp(ctx, audio)).build())
            .setAutoCancel(true)
            .build())
    }

    /** Instant tick when ✓ is pressed, before any transcription. */
    fun tap(ctx: Context) {
        val v = vibrator(ctx)
        val effect = if (Build.VERSION.SDK_INT >= 29) VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
            else VibrationEffect.createOneShot(30, VibrationEffect.DEFAULT_AMPLITUDE)
        try { v.vibrate(effect) } catch (_: Exception) {}
    }

    private fun vibrator(ctx: Context): Vibrator = if (Build.VERSION.SDK_INT >= 31)
        ctx.getSystemService(VibratorManager::class.java).defaultVibrator
    else @Suppress("DEPRECATION") (ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator)

    /** One short buzz when the words are typed in; a clear double buzz when the 10-minute cap cut it off. */
    fun buzz(ctx: Context, double: Boolean) {
        val v = vibrator(ctx)
        val effect = if (double) VibrationEffect.createWaveform(longArrayOf(0, 220, 160, 220), intArrayOf(0, 255, 0, 255), -1)
            else VibrationEffect.createOneShot(45, VibrationEffect.DEFAULT_AMPLITUDE)
        try { v.vibrate(effect) } catch (_: Exception) {}
    }
}
