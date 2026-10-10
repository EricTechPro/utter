package local.utter

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Records the mic ourselves (no system beeps or pop-ups) and transcribes with Whisper
 * on the phone when the user taps ✓.
 */
class VoiceDictation(
    private val ctx: Context,
    private val onLevel: (Float) -> Unit,
    private val onDone: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val rate = 16_000
    @Volatile private var recording = false
    @Volatile private var cancelled = false
    private var worker: Thread? = null
    private val chunks = ArrayList<FloatArray>()

    val isActive get() = recording || worker?.isAlive == true

    @SuppressLint("MissingPermission")
    fun start() {
        if (!Whisper.hasModel(ctx)) { onError("Open Utter to finish setup (voice model)."); return }
        cancelled = false
        chunks.clear()
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_FLOAT, maxOf(minBuf, rate / 5 * 4))
        } catch (e: Exception) { onError("Couldn't open the microphone."); return }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); onError("Couldn't open the microphone."); return }

        recording = true
        worker = thread(name = "utter-record") {
            // Load the model while the user talks, so ✓ is quick.
            thread(name = "utter-load") { Whisper.load(ctx) }
            rec.startRecording()
            val buf = FloatArray(rate / 25)   // 40 ms
            var heardAnything = false
            var readSamples = 0
            while (recording) {
                val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                if (n <= 0) continue
                val piece = buf.copyOf(n)
                synchronized(chunks) { chunks.add(piece) }
                readSamples += n
                var sum = 0f
                for (v in piece) sum += v * v
                val rms = sqrt(sum / n)
                if (rms > 1e-4f) heardAnything = true
                // Same scale the waveform used before (about -2..10).
                val level = ((20 * log10(rms.coerceAtLeast(1e-6f)) + 50) / 40) * 12 - 2
                main.post { onLevel(level) }
                if (readSamples > rate * 2 && !heardAnything) {
                    main.post { onError("Android is blocking the mic for Utter. Open Utter once, then try again.") }
                    recording = false
                    cancelled = true
                }
            }
            rec.stop()
            rec.release()
            if (cancelled) return@thread

            val all = synchronized(chunks) {
                val out = FloatArray(chunks.sumOf { it.size })
                var i = 0
                for (c in chunks) { c.copyInto(out, i); i += c.size }
                out
            }
            if (all.size < rate / 3) { main.post { onDone("") }; return@thread }
            val text = try { Whisper.transcribe(ctx, all) } catch (e: Throwable) { "" }
            main.post { onDone(text) }
        }
    }

    /** Stop recording and transcribe what was said. */
    fun finish() { recording = false }

    fun cancel() {
        cancelled = true
        recording = false
    }
}
