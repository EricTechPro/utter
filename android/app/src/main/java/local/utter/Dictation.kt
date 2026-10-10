package local.utter

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * Continuous dictation on top of Android's speech recognizer.
 * The recognizer stops on each pause, so we keep restarting it and stitch the
 * pieces together until the user taps ✓ (finish) or ✕ (cancel).
 * Uses the on-device recognizer when the phone has one.
 */
class Dictation(
    private val ctx: Context,
    private val onLevel: (Float) -> Unit,
    private val onPartial: (String) -> Unit,
    private val onDone: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private val pieces = mutableListOf<String>()
    private var active = false
    private var finishing = false

    val isActive get() = active

    fun start() {
        if (!SpeechRecognizer.isRecognitionAvailable(ctx)) {
            onError("No speech recognizer on this device. Install or update the Google app.")
            return
        }
        pieces.clear()
        active = true
        finishing = false
        listen()
    }

    /** Stop listening and deliver everything heard so far. */
    fun finish() {
        if (!active) return
        finishing = true
        recognizer?.stopListening()
        // If nothing comes back quickly (no speech), finish with what we have.
        main.postDelayed({ if (active && finishing) complete() }, 2500)
    }

    fun cancel() {
        active = false
        finishing = false
        recognizer?.cancel()
        release()
    }

    private fun listen() {
        release()
        val r = if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
        } else {
            SpeechRecognizer.createSpeechRecognizer(ctx)
        }
        recognizer = r
        r.setRecognitionListener(listener)
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, ctx.packageName)
            if (Build.VERSION.SDK_INT >= 33) putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
            if (Build.VERSION.SDK_INT >= 34) {
                // Pick English or Chinese automatically, and allow switching mid-dictation.
                val langs = arrayListOf("en-US", "zh-CN")
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES, langs)
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH, RecognizerIntent.LANGUAGE_SWITCH_BALANCED)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_SWITCH_ALLOWED_LANGUAGES, langs)
            }
        }
        r.startListening(intent)
    }

    private fun release() {
        recognizer?.destroy()
        recognizer = null
    }

    private fun complete() {
        active = false
        finishing = false
        release()
        onDone(join(pieces).trim())
    }

    /** Spaces between English pieces, none next to Chinese characters. */
    private fun join(parts: List<String>): String = parts.fold("") { acc, p ->
        if (acc.isEmpty()) p
        else if (isCJK(acc.last()) || p.firstOrNull()?.let(::isCJK) == true) acc + p
        else "$acc $p"
    }

    private fun isCJK(c: Char) = Character.UnicodeScript.of(c.code) == Character.UnicodeScript.HAN

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) = onLevel(rmsdB)
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val p = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
            onPartial((pieces + p).joinToString(" "))
        }

        override fun onResults(results: Bundle?) {
            results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                ?.takeIf { it.isNotBlank() }?.let { pieces.add(it.trim()) }
            if (!active) return
            if (finishing) complete() else listen()   // paused mid-thought: keep going
        }

        override fun onError(error: Int) {
            if (!active) return
            when (error) {
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                    if (finishing) complete() else listen()
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    cancel(); onError("Utter needs microphone permission. Open the Utter app to allow it.")
                }
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY, SpeechRecognizer.ERROR_CLIENT ->
                    if (finishing) complete() else main.postDelayed({ if (active) listen() }, 300)
                else -> {
                    if (pieces.isNotEmpty()) complete() else { cancel(); onError("Speech recognition error ($error)") }
                }
            }
        }
    }
}
