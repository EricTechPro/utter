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
    private const val MIN_BYTES = 50_000_000L

    init { System.loadLibrary("utterwhisper") }

    @JvmStatic private external fun nativeInit(path: String): Long
    @JvmStatic private external fun nativeTranscribe(ctx: Long, audio: FloatArray, language: String, threads: Int): String
    @JvmStatic private external fun nativeFree(ctx: Long)

    private var handle = 0L

    fun modelFile(ctx: Context) = File(ctx.filesDir, MODEL)
    fun hasModel(ctx: Context) = modelFile(ctx).let { it.exists() && it.length() > MIN_BYTES }

    /** Downloads the model, reporting 0..1 progress. Runs on the calling thread. */
    fun download(ctx: Context, progress: (Float) -> Unit) {
        val tmp = File(ctx.filesDir, "$MODEL.part")
        val conn = URL(URL_MODEL).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 15_000
        conn.readTimeout = 30_000
        conn.connect()
        if (conn.responseCode !in 200..299) throw IllegalStateException("Download failed (${conn.responseCode})")
        val total = conn.contentLengthLong.takeIf { it > 0 } ?: 60_000_000L
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
        if (tmp.length() < MIN_BYTES) { tmp.delete(); throw IllegalStateException("Download was incomplete") }
        tmp.renameTo(modelFile(ctx))
    }

    @Synchronized
    fun load(ctx: Context): Boolean {
        if (handle != 0L) return true
        if (!hasModel(ctx)) return false
        handle = nativeInit(modelFile(ctx).absolutePath)
        return handle != 0L
    }

    /** 16 kHz mono samples in, cleaned-up text out. Blocking; call off the main thread. */
    @Synchronized
    fun transcribe(ctx: Context, samples: FloatArray): String {
        if (!load(ctx)) return ""
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(2, 6)
        return clean(nativeTranscribe(handle, samples, "auto", threads))
    }

    /** Drops [BLANK_AUDIO]-style tags; Chinese comes out Simplified with Chinese punctuation. */
    fun clean(raw: String): String {
        var t = raw.replace(Regex("""\[[^\]]*]|\([^)]*\)|\*[^*]*\*|♪"""), " ")
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
        return t
    }
}
