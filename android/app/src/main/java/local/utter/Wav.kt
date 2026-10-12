package local.utter

import android.content.Context
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Where recordings live until they're transcribed. A file still here means it wasn't finished. */
object Recordings {
    fun dir(ctx: Context) = File(ctx.filesDir, "recordings").apply { mkdirs() }
    fun newFile(ctx: Context) = File(dir(ctx), "rec-${System.currentTimeMillis()}.wav")
    fun unfinished(ctx: Context, except: File? = null): List<File> =
        (dir(ctx).listFiles { f -> f.extension == "wav" } ?: emptyArray())
            .filter { it != except && it.length() > 44 }
            .sortedByDescending { it.lastModified() }

    /** Text of the chunks already transcribed, saved next to the audio as it goes. */
    fun partialText(wav: File) = File(wav.path + ".txt")

    fun delete(wav: File) { wav.delete(); partialText(wav).delete() }

    /**
     * After a crash, kill or power loss the header still says 0 bytes; write the real sizes so
     * the file plays anywhere. Readers here ignore the header anyway.
     */
    fun repair(wav: File) {
        try {
            val data = wav.length() - 44
            if (data <= 0) return
            RandomAccessFile(wav, "rw").use { f ->
                f.seek(40)
                val cur = Integer.reverseBytes(f.readInt()).toLong() and 0xFFFFFFFFL
                if (cur == data) return
                f.seek(4); f.writeInt(Integer.reverseBytes((36 + data).toInt()))
                f.seek(40); f.writeInt(Integer.reverseBytes(data.toInt()))
            }
        } catch (_: Exception) {}
    }
}

/** Streams 16 kHz mono audio to a 16-bit WAV on disk, so long recordings never sit in memory. */
class WavWriter(val file: File, private val rate: Int = 16_000) {
    private val fos = FileOutputStream(file)
    private val out = BufferedOutputStream(fos, 64 * 1024)
    private var dataBytes = 0L
    private var syncedAt = 0L
    private val bb = ByteBuffer.allocate(4096 * 2).order(ByteOrder.LITTLE_ENDIAN)

    init { out.write(header(0)) }

    fun write(samples: FloatArray, n: Int = samples.size) {
        var i = 0
        while (i < n) {
            bb.clear()
            val end = minOf(n, i + 4096)
            while (i < end) {
                bb.putShort((samples[i].coerceIn(-1f, 1f) * 32767f).toInt().toShort()); i++
            }
            out.write(bb.array(), 0, bb.position())
            dataBytes += bb.position()
        }
        // Every ~2 s push it to storage, so a power cut or kill loses at most a moment.
        if (dataBytes - syncedAt >= rate * 2 * 2) {
            syncedAt = dataBytes
            try { out.flush(); fos.fd.sync() } catch (_: Exception) {}
        }
    }

    /** Flushes and writes the real sizes into the header. */
    fun close() {
        out.flush(); out.close()
        RandomAccessFile(file, "rw").use { it.seek(0); it.write(header(dataBytes)) }
    }

    private fun header(data: Long): ByteArray = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray()); putInt((36 + data).toInt()); put("WAVE".toByteArray())
        put("fmt ".toByteArray()); putInt(16); putShort(1); putShort(1)
        putInt(rate); putInt(rate * 2); putShort(2); putShort(16)
        put("data".toByteArray()); putInt(data.toInt())
    }.array()
}

/**
 * Reads a WAV written by [WavWriter] in pieces, ignoring the header sizes
 * (they're zero if the app died mid-recording).
 */
fun readWavPieces(file: File, pieceSamples: Int = 16_000, onPiece: (FloatArray) -> Unit) {
    file.inputStream().buffered().use { input ->
        input.skip(44)
        val bytes = ByteArray(pieceSamples * 2)
        while (true) {
            var got = 0
            while (got < bytes.size) {
                val n = input.read(bytes, got, bytes.size - got)
                if (n < 0) break
                got += n
            }
            if (got < 2) break
            val sb = ByteBuffer.wrap(bytes, 0, got - got % 2).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
            onPiece(FloatArray(sb.remaining()) { sb.get(it) / 32768f })
            if (got < bytes.size) break
        }
    }
}
