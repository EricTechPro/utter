package local.utter

import android.content.Context
import android.os.Build
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * On-device speech to text with whisper.cpp (same engine as the Mac app).
 * The model (~60 MB) is downloaded once on first setup and kept in app storage.
 */
object Whisper {
    private const val MODEL = "ggml-base-q5_1.bin"
    private const val URL_MODEL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
    /** Exact size of ggml-base-q5_1.bin; anything else is a broken or partial download. */
    private const val MODEL_BYTES = 59_707_625L

    init {
        // Phones without the ARMv8.2 dot-product instructions get a plain ARMv8 build (slower,
        // but it runs); everything newer (Pixel 4 and later) gets the fast one.
        val fast = try { java.io.File("/proc/cpuinfo").readText().contains(Regex("""\basimddp\b""")) } catch (_: Exception) { true }
        try { System.loadLibrary(if (fast) "utterwhisper" else "utterwhisper_v8") }
        catch (e: UnsatisfiedLinkError) { System.loadLibrary("utterwhisper_v8") }
    }

    @JvmStatic private external fun nativeInit(path: String): Long
    @JvmStatic private external fun nativeTranscribe(ctx: Long, audio: FloatArray, language: String, prompt: String, threads: Int, audioCtx: Int, fallback: Boolean): String?
    @JvmStatic private external fun nativeLastEndMs(ctx: Long): Int
    @JvmStatic private external fun nativeFree(ctx: Long)

    private var handle = 0L

    fun modelFile(ctx: Context) = File(ctx.filesDir, MODEL)
    fun hasModel(ctx: Context) = modelFile(ctx).let { it.exists() && it.length() == MODEL_BYTES }

    /** Downloads the model, reporting 0..1 progress. Runs on the calling thread. */
    fun download(ctx: Context, progress: (Float) -> Unit) {
        // A fresh temp file per attempt, so two downloads can never write into the same one.
        ctx.filesDir.listFiles { f -> f.name.startsWith("$MODEL.") && f.name.endsWith(".part") }?.forEach { it.delete() }
        val tmp = File(ctx.filesDir, "$MODEL.${System.nanoTime()}.part")
        val conn = URL(URL_MODEL).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.connect()
        if (conn.responseCode !in 200..299) throw IllegalStateException("Download failed (${conn.responseCode})")
        val total = conn.contentLengthLong.takeIf { it > 0 } ?: MODEL_BYTES
        conn.inputStream.use { input ->
            tmp.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var done = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    done += n
                    progress((done.toFloat() / total).coerceAtMost(1f))
                }
            }
        }
        if (tmp.length() != MODEL_BYTES || (conn.contentLengthLong > 0 && tmp.length() != conn.contentLengthLong)) {
            tmp.delete(); throw IllegalStateException("Download was incomplete")
        }
        if (!tmp.renameTo(modelFile(ctx))) { tmp.delete(); throw IllegalStateException("Couldn't save the model") }
    }

    @Synchronized
    fun load(ctx: Context): Boolean {
        if (handle != 0L) return true
        if (!hasModel(ctx)) return false
        handle = nativeInit(modelFile(ctx).absolutePath)
        // A model file that won't load is useless: delete it so the app offers Download again.
        if (handle == 0L) modelFile(ctx).delete()
        return handle != 0L
    }

    /**
     * Primer for every chunk: Eric mixes Mandarin and English in one sentence. Without it the
     * base model drops or translates the other language; with it, a mixed test clip came out
     * as spoken (checked on the Mac with the same model and settings).
     */
    const val PRIMER = "我们下午开会，then I need to review the pull request，然后把 document 发给你。OK, sounds good."

    /**
     * Raw whisper text. Language is fixed to "zh" with the mixed primer: in tests that kept
     * English as English, Chinese as Simplified Chinese, and mixed sentences as spoken, and it
     * skips whisper's language-detection pass (a whole extra encoder run per chunk).
     * Chunks up to ~15 s use a 15 s encoder window instead of 30 s. Throws on failure.
     */
    @Synchronized
    fun transcribeRaw(ctx: Context, samples: FloatArray, language: String = "zh", prompt: String = PRIMER): String {
        if (!load(ctx)) throw IllegalStateException("Voice model not loaded")
        val out = StringBuilder()
        var from = 0
        // Whisper can end a chunk early (often right after switching language), dropping the rest.
        // If speech is left after the last segment, run again on just that part (at most twice).
        for (pass in 0 until 3) {
            val piece = if (from == 0) samples else samples.copyOfRange(from, samples.size)
            val audioCtx = if (piece.size <= 16_000 * 15) 768 else 0
            // The leftover is usually the other language: let whisper detect it, and don't retry hot.
            val text = nativeTranscribe(handle, piece, if (pass == 0) language else "auto", prompt, THREADS, audioCtx, pass == 0)
                ?: throw IllegalStateException("Transcription failed")
            // On near-silence whisper sometimes just repeats the primer back; drop only a near-copy.
            if (!isPrimerEcho(text)) out.append(text)
            val endMs = nativeLastEndMs(handle)
            val next = from + endMs * 16
            // Skip the extra pass for a tiny leftover (under 1.5 s, or under ~0.5 s of actual speech).
            if (endMs <= 0 || next >= samples.size - 24_000 || !hasSpeech(samples, next)) break
            from = next
        }
        return out.toString()
    }

    /** At least ~0.5 s of 100 ms windows above a speech-ish level after `from`. */
    private fun hasSpeech(a: FloatArray, from: Int): Boolean {
        var loud = 0
        var s = from
        while (s + 1600 <= a.size) {
            var sum = 0f
            for (i in s until s + 1600) sum += a[i] * a[i]
            if (Math.sqrt((sum / 1600).toDouble()) > 0.008) loud++
            s += 1600
        }
        return loud >= 5
    }

    /**
     * Big cores only. Background-ish processes are also limited to the little cores, so
     * more threads just fight each other (Pixel 9: 4 little, 3 mid, 1 prime).
     */
    private val THREADS = Runtime.getRuntime().availableProcessors().let { if (it >= 8) 4 else (it / 2).coerceAtLeast(2) }

    private fun norm(t: String) = t.lowercase().filter { it.isLetterOrDigit() }

    /** True only when the text is basically the whole primer (at least 80% similar, similar length). */
    fun isPrimerEcho(text: String): Boolean {
        val a = norm(text)
        val b = norm(PRIMER)
        if (a.isEmpty() || a.length < b.length * 0.7 || a.length > b.length * 1.3) return false
        var prev = IntArray(b.length + 1) { it }   // Levenshtein distance
        for (i in 1..a.length) {
            val cur = IntArray(b.length + 1)
            cur[0] = i
            for (j in 1..b.length) {
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            }
            prev = cur
        }
        return 1.0 - prev[b.length].toDouble() / maxOf(a.length, b.length) > 0.8
    }

    /** Phrases whisper tends to produce from near-silence (same list as the Mac app). Only use on quiet audio. */
    fun isHallucination(t: String): Boolean {
        val s = t.lowercase().trim { it.isWhitespace() || !it.isLetterOrDigit() }
        return s in setOf("thank you", "thanks for watching", "you", "bye", "thank you for watching", "okay")
    }

    /** Drops [BLANK_AUDIO]-style tags; Chinese comes out Simplified with Chinese punctuation. */
    fun clean(raw: String): String {
        // Whisper sometimes writes a lone full-width zero where a pause/comma belongs.
        val fixed = raw.replace('﹑', '，').replace('、', '，').replace(Regex("""(?<![0-9０-９])０(?![0-9０-９])"""), "，")
        var t = java.text.Normalizer.normalize(fixed, java.text.Normalizer.Form.NFKC)
            .replace(Regex("""\[[^\]]*]|\([^)]*\)|\*[^*]*\*|♪"""), " ")
            .replace(Regex("""\s+"""), " ").trim()
        if (t.any { Character.UnicodeScript.of(it.code) == Character.UnicodeScript.HAN }) {
            if (Build.VERSION.SDK_INT >= 29) {
                t = android.icu.text.Transliterator.getInstance("Hant-Hans").transliterate(t)
            }
            val han = """\p{IsHan}"""
            t = t.replace(Regex("""($han)\s*,"""), "$1，").replace(Regex("""($han)\s*\."""), "$1。")
                .replace(Regex("""($han)\s*\?"""), "$1？").replace(Regex("""($han)\s*!"""), "$1！")
                .replace(Regex("""($han|[，。？！])\s+($han)"""), "$1$2")
        }
        // NFKC turns "，" into "," with no space: put the space back before Latin words.
        t = t.replace(Regex("""([,;?!])(?=[A-Za-z])"""), "$1 ")
            .replace(Regex("""(?<=[\p{IsHan}a-z]{2})\.(?=[A-Z])"""), ". ")
        return t.replace(Regex("([。，！？])\\1+"), "$1").replace(Regex("""\.,|,\."""), ".")
    }
}
