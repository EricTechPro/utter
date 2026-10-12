package local.utter

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.sqrt

/**
 * Records like a voice recorder: the mic goes straight to a WAV file on disk (so length can't
 * run us out of memory), and finished short chunks (3–10 s, cut at pauses) are transcribed with Whisper while you're
 * still talking, so after you stop only the last bit is left. Stops by itself at [MAX_SECONDS].
 */
class VoiceDictation(
    private val ctx: Context,
    private val onLevel: (Float) -> Unit,
    /** Recording ended (you tapped stop, or the cap was hit); text is still being finished. */
    private val onStopped: (capped: Boolean) -> Unit,
    private val onDone: (Result) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object {
        /** The one recording cap. At this length it stops, transcribes and pastes by itself. */
        const val MAX_SECONDS = 600

        const val RATE = 16_000

        /** The file being recorded right now, so the app doesn't offer it as "unfinished". */
        @Volatile var currentFile: File? = null
            private set
    }

    /** `text` is null when transcription failed; the audio file is then kept for a retry. */
    data class Result(val text: String?, val capped: Boolean, val audio: File, val seconds: Int)

    private val main = Handler(Looper.getMainLooper())

    /** One recording. Each tap gets a fresh one, so a discarded take finishing in the background never blocks the next. */
    private class Session {
        @Volatile var recording = false
        @Volatile var cancelled = false
        @Volatile var capped = false
        @Volatile var samples = 0L
        var worker: Thread? = null
    }
    @Volatile private var cur: Session? = null

    /** Recording, or finishing the words of a take that wasn't discarded. */
    val isActive get() = cur?.let { it.recording || (!it.cancelled && it.worker?.isAlive == true) } == true
    val isRecording get() = cur?.recording == true
    val elapsedSeconds get() = ((cur?.samples ?: 0L) / RATE).toInt()

    @SuppressLint("MissingPermission")
    fun start(): Boolean {
        if (isActive) return false
        if (!Whisper.hasModel(ctx)) { onError("Open Utter to finish setup (voice model)."); return false }
        val minBuf = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_FLOAT, maxOf(minBuf, RATE / 5 * 4))
        } catch (e: Exception) { onError("Couldn't open the microphone."); return false }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); onError("Couldn't open the microphone."); return false }
        try { rec.startRecording() } catch (_: Exception) {}
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release(); onError("Couldn't start the microphone. Another app may be using it."); return false
        }
        val file = Recordings.newFile(ctx)
        val wav = try { WavWriter(file, RATE) } catch (e: Exception) {
            try { rec.stop() } catch (_: Exception) {}
            rec.release(); onError("Couldn't save the recording."); return false
        }
        currentFile = file
        // Keep the CPU awake with the screen off, for recording and for the last chunk.
        val wake = (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "utter:recording")
            .apply { acquire((MAX_SECONDS + 300) * 1000L) }

        val s = Session().apply { recording = true }
        cur = s
        s.worker = thread(name = "utter-record") {
            try {
                record(s, rec, wav, file)
            } finally {
                if (currentFile == file) currentFile = null
                if (wake.isHeld) wake.release()
            }
        }
        return true
    }

    private fun record(s: Session, rec: AudioRecord, wav: WavWriter, file: File) {
        thread(name = "utter-load") { try { Whisper.load(ctx) } catch (_: Throwable) {} }
        val transcriber = ChunkTranscriber(ctx, Recordings.partialText(file))
        val chunker = Chunker(RATE) { transcriber.submit(it) }
        val max = MAX_SECONDS.toLong() * RATE
        var heardAnything = false
        var emptyReads = 0
        try {
            val buf = FloatArray(RATE / 25)   // 40 ms
            while (s.recording) {
                val n = rec.read(buf, 0, buf.size, AudioRecord.READ_BLOCKING)
                if (n < 0) throw IllegalStateException("AudioRecord.read failed: $n")
                if (n == 0) {
                    // Nothing came back: back off instead of spinning; give up after ~2 s.
                    if (++emptyReads > 100) throw IllegalStateException("Microphone returned no audio")
                    Thread.sleep(20)
                    continue
                }
                emptyReads = 0
                wav.write(buf, n)
                chunker.append(buf, n)
                s.samples += n
                var sum = 0f
                for (i in 0 until n) sum += buf[i] * buf[i]
                val rms = sqrt(sum / n)
                if (rms > 1e-4f) heardAnything = true
                val db = 20 * log10(rms.coerceAtLeast(1e-6f))   // dBFS, for the waveform
                if (cur === s) main.post { onLevel(db) }
                if (s.samples > RATE * 2 && !heardAnything) {
                    main.post { onError("Android is blocking the mic for Utter. Open Utter once, then try again.") }
                    s.cancelled = true
                    s.recording = false
                }
                if (s.samples >= max) { s.capped = true; s.recording = false }
            }
        } catch (e: Throwable) {
            android.util.Log.e("Utter", "recording stopped", e)
            if (!s.cancelled) {
                // Keep what was recorded: treat it like a stop.
                main.post { onError("The microphone stopped. What you said so far is kept.") }
            }
            s.recording = false
        } finally {
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
            try { wav.close() } catch (_: Exception) {}
        }

        if (s.cancelled) { transcriber.abort(); Recordings.delete(file); return }
        val wasCapped = s.capped
        main.post { if (!s.cancelled) onStopped(wasCapped) }
        val seconds = (s.samples / RATE).toInt()
        if (s.samples < RATE / 3) {
            transcriber.abort(); Recordings.delete(file)
            main.post { if (!s.cancelled) onDone(Result("", wasCapped, file, seconds)) }
            return
        }
        val stopAt = System.currentTimeMillis()
        chunker.flush()
        val text = transcriber.finish()
        android.util.Log.i("Utter", "stop -> text ${System.currentTimeMillis() - stopAt} ms for ${seconds}s of audio")
        // ✕ may have raced the stop or the cap: a discarded take is never delivered.
        if (s.cancelled) { Recordings.delete(file); return }
        if (text != null) Recordings.delete(file)   // delivered; on failure the WAV stays for a retry
        main.post { if (!s.cancelled) onDone(Result(text, wasCapped, file, seconds)) }
    }

    /** Stop recording and transcribe what was said. */
    fun finish() { cur?.recording = false }

    /** Stop and throw the recording away. */
    fun cancel() {
        cur?.let { it.cancelled = true; it.recording = false }
    }
}

/**
 * Cuts a 16 kHz stream into short chunks so Whisper keeps up while you talk: at a ≥0.4 s pause
 * once a chunk is [minSeconds] long,
 * or at the quietest moment of the last few seconds when it reaches [maxSeconds].
 * Chunks with almost no speech are dropped (Whisper invents words in silence).
 */
class Chunker(
    private val rate: Int,
    minSeconds: Int = 3,
    maxSeconds: Int = 10,
    private val onChunk: (FloatArray) -> Unit,
) {
    private val buf = FloatArray(rate * maxSeconds)
    private var len = 0
    private val min = rate * minSeconds

    fun append(s: FloatArray, n: Int = s.size) {
        var i = 0
        while (i < n) {
            val take = minOf(n - i, buf.size - len)
            System.arraycopy(s, i, buf, len, take)
            len += take
            i += take
            if (len == buf.size) forceCut()
        }
        // A ≥0.4 s pause closes the chunk, so at stop only the words since the last pause are left.
        if (len >= min && rms(buf, len - rate * 2 / 5, len) < 0.008f) flush()
    }

    fun flush() {
        if (len == 0) return
        emit(buf.copyOf(len))
        len = 0
    }

    private fun forceCut() {
        // Quietest 100 ms window in the last 4 s, so we don't cut through a word.
        val win = rate / 10
        var cut = len
        var best = Float.MAX_VALUE
        var start = maxOf(0, len - rate * 4)
        while (start + win <= len) {
            val r = rms(buf, start, start + win)
            if (r < best) { best = r; cut = start + win / 2 }
            start += win / 2
        }
        emit(buf.copyOf(cut))
        System.arraycopy(buf, cut, buf, 0, len - cut)
        len -= cut
    }

    private fun emit(chunk: FloatArray) {
        // Need at least ~0.3 s of 100 ms windows above a whisper-level floor.
        val win = rate / 10
        var loud = 0
        var s = 0
        while (s + win <= chunk.size) { if (rms(chunk, s, s + win) > 0.008f) loud++; s += win }
        if (loud >= 3 || (chunk.size < win && rms(chunk, 0, chunk.size) > 0.008f)) onChunk(chunk)
    }

    private fun rms(a: FloatArray, from: Int, to: Int): Float {
        val f = from.coerceAtLeast(0)
        if (to <= f) return 0f
        var sum = 0f
        for (i in f until to) sum += a[i] * a[i]
        return sqrt(sum / (to - f))
    }
}

/**
 * Runs Whisper on chunks one at a time, in order. Each chunk detects its own language and
 * gets the mixed Chinese/English primer, so switching languages mid-recording is kept.
 */
class ChunkTranscriber(private val ctx: Context, private val partial: File? = null) {
    private val pool = Executors.newSingleThreadExecutor { r -> Thread(r, "utter-whisper") }
    private val parts = ArrayList<String>()
    @Volatile private var failed = false

    fun submit(chunk: FloatArray) {
        pool.execute {
            if (failed) return@execute
            try {
                val t0 = System.currentTimeMillis()
                val t = Whisper.clean(Whisper.transcribeRaw(ctx, chunk))
                android.util.Log.i("Utter", "chunk ${"%.1f".format(chunk.size / 16000f)}s -> ${System.currentTimeMillis() - t0} ms")
                // Stock phrases ("Thank you", "Okay") are only treated as invented when the audio was quiet.
                if (t.isNotBlank() && !(Whisper.isHallucination(t) && peakRms(chunk) < 0.02f)) {
                    synchronized(parts) { parts.add(t) }
                    // Keep finished text on disk too, so a crash or power cut doesn't lose it.
                    try { partial?.appendText(t + "\n") } catch (_: Exception) {}
                }
            } catch (e: Throwable) {
                android.util.Log.e("Utter", "chunk failed", e)
                failed = true
            }
        }
    }

    /** Waits for every chunk; returns the whole text, or null if any chunk failed. */
    fun finish(): String? {
        pool.shutdown()
        pool.awaitTermination(30, TimeUnit.MINUTES)
        if (failed) return null
        return Whisper.clean(synchronized(parts) { parts.joinToString(" ") })
    }

    fun abort() { failed = true; pool.shutdownNow() }

    private fun peakRms(a: FloatArray): Float {
        var peak = 0f
        var s = 0
        while (s + 1600 <= a.size) {
            var sum = 0f
            for (i in s until s + 1600) sum += a[i] * a[i]
            peak = maxOf(peak, sqrt(sum / 1600))
            s += 1600
        }
        return peak
    }
}
