package local.utter

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.Toast
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Shows a small dark mic button with a red ring whenever the keyboard is up, in any app.
 * Tap it and it records like a voice recorder (screen can go off, you can switch apps):
 * the button grows into a pill with ✕ (discard), a waveform, the time used, and ✓ (stop).
 * The words are typed into whichever text box is selected when they're ready; at
 * [VoiceDictation.MAX_SECONDS] it stops by itself and buzzes twice. Drag the button anywhere.
 */
class BubbleService : AccessibilityService() {
    companion object {
        private const val PILL_W = 320
        /** "Transcribing" / "Pasted" capsule: the pill shrinks to this. */
        private const val COMPACT_W = 200
        private const val BUBBLE = 56
        private const val BUBBLE_PAD = 8
        /** How long "Pasted" / "Copied" stays on the pill before it goes back to the button. */
        private const val CONFIRM_MS = 1400L
        var running = false
            private set
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var wm: WindowManager
    private lateinit var params: WindowManager.LayoutParams
    private lateinit var root: FrameLayout
    private lateinit var bubble: FrameLayout
    private lateinit var pill: FrameLayout
    private lateinit var recRow: LinearLayout
    private lateinit var statusRow: LinearLayout
    private lateinit var ring: CalmRing
    private lateinit var statusIcon: ImageView
    private lateinit var statusText: android.widget.TextView
    private lateinit var recDot: View
    private lateinit var pillBg: GradientDrawable
    private lateinit var wave: WaveView
    private lateinit var clock: android.widget.TextView
    /** True while "Pasted"/"Copied" is showing, so focus changes don't hide it early. */
    private var holding = false
    private var shown = false
    private var target: AccessibilityNodeInfo? = null
    private var dictation: VoiceDictation? = null
    /** Re-checks before hiding: only hides if the keyboard is really gone (no flicker between fields). */
    private val hideRunnable = Runnable {
        if (dictation?.isActive == true || holding || !shown) return@Runnable
        if (keyboardVisible() && focusedInput()?.isPassword != true) return@Runnable
        logState("hide", null, "keyboard gone")
        hide()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onServiceConnected() {
        running = true
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        buildViews()
        dictation = VoiceDictation(
            this,
            onLevel = { wave.push(it) },
            onStopped = { stopped() },
            onDone = { result -> finished(result) },
            onError = { msg -> stopTicking(); RecordingService.stop(this); toast(msg); showBubble() },
        )
        RecordingService.onStopRequested = { main.post { finish() } }
        // Recordings left from a crash, kill or power cut: fix their headers and offer a retry.
        Thread {
            val left = Recordings.unfinished(this, except = VoiceDictation.currentFile)
            left.forEach { Recordings.repair(it) }
            if (left.isNotEmpty() && left.first().lastModified() > lastNotifiedRecovery()) {
                getSharedPreferences("utter", MODE_PRIVATE).edit().putLong("recoveryNotified", left.first().lastModified()).apply()
                Notify.interrupted(this, left.first(), left.size)
            }
        }.start()
    }

    private fun lastNotifiedRecovery() = getSharedPreferences("utter", MODE_PRIVATE).getLong("recoveryNotified", 0)

    override fun onDestroy() {
        running = false
        RecordingService.onStopRequested = null
        // Don't lose a recording if Utter is turned off mid-way: stop it and let it finish
        // (the text goes to the clipboard and History; on failure the audio is kept).
        dictation?.finish()
        stopTicking()
        closePopup()
        hide()
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (dictation?.isActive == true || holding) return
        // Coalesce bursts (content-changed events can come in floods): evaluate at most every ~120 ms.
        lastEventPkg = event?.packageName?.toString() ?: lastEventPkg
        if (!evalPending) { evalPending = true; main.postDelayed(evaluate, 120) }
    }

    private var evalPending = false
    private var lastEventPkg = ""
    private var lastLogged = ""

    /**
     * Show while you're typing anywhere. The keyboard being up is the strong signal: many apps
     * (Compose, React Native, WebViews, custom editors like ChatGPT's) don't report a focused
     * "editable" node, or report it late while focus hops between fields. So: keyboard up and
     * no password field focused -> show. Hiding is debounced and re-checked, so a hop between
     * fields never hides the button.
     */
    private val evaluate = Runnable {
        evalPending = false
        if (dictation?.isActive == true || holding) return@Runnable
        val ime = keyboardVisible()
        val node = focusedInput()
        val password = node?.isPassword == true
        if (ime && !password) {
            main.removeCallbacks(hideRunnable)
            if (node != null) target = node
            if (!shown) logState("show", node, if (node?.isEditable == true) "keyboard+editable" else "keyboard")
            show()
        } else if (shown) {
            main.removeCallbacks(hideRunnable)
            main.postDelayed(hideRunnable, 700)
        }
    }

    private fun logState(what: String, node: AccessibilityNodeInfo?, reason: String) {
        if (!BuildConfig.DEBUG) return
        val line = "$what pkg=${node?.packageName ?: lastEventPkg} reason=$reason"
        if (line != lastLogged) { lastLogged = line; android.util.Log.d("UtterBubble", line) }
    }

    /** The on-screen keyboard is showing (an input-method window with real size). */
    private fun keyboardVisible(): Boolean {
        val ws = windows ?: return false
        return ws.any {
            it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD &&
                android.graphics.Rect().also { r -> it.getBoundsInScreen(r) }.height() > 0
        }
    }

    /**
     * The node with input focus, looking in the focused window first, then the active one, then
     * every window. Prefers an editable node but falls back to whatever holds input focus
     * (custom editors), which is still where the words should go.
     */
    private fun focusedInput(): AccessibilityNodeInfo? {
        val ws = windows.orEmpty().filter { it.type != android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
        val roots = (ws.filter { it.isFocused }.mapNotNull { it.root } + listOfNotNull(rootInActiveWindow) +
            ws.filter { !it.isFocused }.mapNotNull { it.root })
        var fallback: AccessibilityNodeInfo? = null
        for (r in roots) {
            val f = r.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: continue
            if (f.isEditable) return f
            if (fallback == null) fallback = f
        }
        return fallback
    }

    /** A focused, editable, non-password field to type into (for pasting the result). */
    private fun focusedEditable(): AccessibilityNodeInfo? =
        focusedInput()?.takeIf { !it.isPassword }

    // ---- Views ----------------------------------------------------------------

    private fun buildViews() {
        root = FrameLayout(this)

        // Resting button: the Mac dock's dark capsule, with a red ring and red mic so it stands
        // out on light and dark apps alike, and a soft shadow to lift it off the page.
        bubble = FrameLayout(this).apply {
            background = android.graphics.drawable.LayerDrawable(arrayOf(
                GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Theme.CAPSULE); setStroke(dp(1), 0x40FFFFFF) },
                GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0); setStroke(dp(2), Theme.RED) },
            )).apply { setLayerInset(1, dp(3), dp(3), dp(3), dp(3)) }
            elevation = dp(10).toFloat()
            outlineProvider = android.view.ViewOutlineProvider.BACKGROUND
            outlineAmbientShadowColor = Color.BLACK
            outlineSpotShadowColor = Color.BLACK
            addView(ImageView(context).apply {
                setImageResource(R.drawable.ic_mic)
                imageTintList = android.content.res.ColorStateList.valueOf(Theme.RED)
            }, FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER))
        }
        // Room around it so the shadow isn't clipped by the overlay window.
        root.setPadding(dp(BUBBLE_PAD), dp(BUBBLE_PAD), dp(BUBBLE_PAD), dp(BUBBLE_PAD))
        root.clipToPadding = false
        root.addView(bubble, FrameLayout.LayoutParams(dp(BUBBLE), dp(BUBBLE)))

        val close = ImageView(this).apply {
            setImageResource(R.drawable.ic_close)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0xFF595959.toInt()) }
            contentDescription = "Discard"
            setOnClickListener { cancel() }
        }
        recDot = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Theme.RED) }
        }
        wave = WaveView(this)
        clock = android.widget.TextView(this).apply {
            textSize = 13f; setTextColor(Theme.CREAM)
            typeface = Theme.sans(context, 600)
            fontFeatureSettings = "tnum"
            maxLines = 1
        }
        val done = ImageView(this).apply {
            setImageResource(R.drawable.ic_check)
            setPadding(dp(9), dp(9), dp(9), dp(9))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }
            contentDescription = "Stop and type it in"
            setOnClickListener { finish() }
        }
        recRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(close, LinearLayout.LayoutParams(dp(40), dp(40)))
            addView(recDot, LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginStart = dp(12) })
            addView(wave, LinearLayout.LayoutParams(0, dp(36), 1f).apply { marginStart = dp(8); marginEnd = dp(10) })
            addView(clock, LinearLayout.LayoutParams(-2, -2).apply { marginEnd = dp(10) })
            addView(done, LinearLayout.LayoutParams(dp(40), dp(40)))
        }
        ring = CalmRing(this)
        statusIcon = ImageView(this).apply {
            setImageResource(R.drawable.ic_check)
            imageTintList = android.content.res.ColorStateList.valueOf(Theme.GREEN)
        }
        statusText = android.widget.TextView(this).apply {
            textSize = 14f; setTextColor(Theme.CREAM); typeface = Theme.sans(context, 600); maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        // Compact state: "Transcribing…" with a small, slowly turning ring on the right.
        // Then a check and "Pasted". Nothing blinks.
        statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(14), 0, dp(14), 0)
            addView(statusIcon, LinearLayout.LayoutParams(dp(18), dp(18)).apply { marginEnd = dp(6) })
            addView(statusText, LinearLayout.LayoutParams(-2, -2))
            addView(ring, LinearLayout.LayoutParams(dp(16), dp(16)).apply { marginStart = dp(10) })
            visibility = View.GONE
        }
        pillBg = GradientDrawable().apply { setColor(Theme.CAPSULE); cornerRadius = dp(28).toFloat() }
        pill = FrameLayout(this).apply {
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = pillBg
            elevation = dp(8).toFloat()
            addView(recRow, FrameLayout.LayoutParams(-1, -1))
            addView(statusRow, FrameLayout.LayoutParams(-1, -1))
            visibility = View.GONE
        }
        root.addView(pill, FrameLayout.LayoutParams(dp(PILL_W), dp(56)))

        val prefs = getSharedPreferences("utter", MODE_PRIVATE)
        val screenW = resources.displayMetrics.widthPixels
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt("x", screenW - dp(BUBBLE + 2 * BUBBLE_PAD) - dp(4))
            y = prefs.getInt("y", (resources.displayMetrics.heightPixels * 0.35).toInt())
        }

        bubble.setOnTouchListener(DragListener())
    }

    private inner class DragListener : View.OnTouchListener {
        private var downX = 0f
        private var downY = 0f
        private var startX = 0
        private var startY = 0
        private var dragging = false

        override fun onTouch(v: View, e: MotionEvent): Boolean {
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = e.rawX; downY = e.rawY; startX = params.x; startY = params.y; dragging = false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (!dragging && (abs(dx) > dp(8) || abs(dy) > dp(8))) dragging = true
                    if (dragging) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        wm.updateViewLayout(root, params)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (dragging) snapToEdge() else { v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP); start() }
                }
            }
            return true
        }
    }

    private fun snapToEdge() {
        val w = resources.displayMetrics.widthPixels
        params.x = if (params.x + dp(BUBBLE / 2 + BUBBLE_PAD) < w / 2) dp(4) else w - dp(BUBBLE + 2 * BUBBLE_PAD) - dp(4)
        params.y = params.y.coerceIn(dp(40), resources.displayMetrics.heightPixels - dp(120))
        wm.updateViewLayout(root, params)
        getSharedPreferences("utter", MODE_PRIVATE).edit().putInt("x", params.x).putInt("y", params.y).apply()
    }

    private fun show() {
        if (shown) return
        showBubble()
        try { wm.addView(root, params); shown = true } catch (_: Exception) {}
    }

    private fun hide() {
        if (!shown) return
        try { wm.removeView(root) } catch (_: Exception) {}
        shown = false
    }

    private fun showBubble() {
        holding = false
        pill.visibility = View.GONE
        bubble.visibility = View.VISIBLE
        // Back to where the button was before the pill had to shift left to fit.
        bubbleX?.let { params.x = it }
        bubbleX = null
        if (shown) wm.updateViewLayout(root, params)
    }

    private var bubbleX: Int? = null

    private fun showPill() {
        bubble.visibility = View.GONE
        pill.visibility = View.VISIBLE
        wave.reset()
        pillAnim?.cancel()
        pill.layoutParams = pill.layoutParams.apply { width = dp(PILL_W) }
        setRecordingLook()
        // Keep the pill on screen when the button sits on the right edge.
        val w = resources.displayMetrics.widthPixels
        if (bubbleX == null) bubbleX = params.x
        params.x = min(params.x, w - dp(PILL_W) - dp(12) - dp(2 * BUBBLE_PAD)).coerceAtLeast(0)
        if (shown) wm.updateViewLayout(root, params)
    }

    // ---- Dictation ------------------------------------------------------------

    private fun start() {
        if (dictation?.isActive == true) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            toast("Open Utter and allow the microphone first.")
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        target = focusedEditable() ?: target
        closePopup()
        showPill()
        if (dictation?.start() == true) {
            RecordingService.start(this)
            startTicking()
            pulseDot()
        } else {
            showBubble()
        }
    }

    /** ✓ or the notification's Stop: release the mic now; the words are typed in when ready. */
    private fun finish() {
        if (dictation?.isRecording != true) return
        Notify.tap(this)
        dictation?.finish()
        stopped()
    }

    private fun cancel() {
        dictation?.cancel()
        stopTicking()
        RecordingService.stop(this)
        showBubble()
    }

    /** Recording ended (✓ or the cap): switch to "Transcribing…" right away. */
    private fun stopped() {
        stopTicking()
        setStatus(working = true, "Transcribing…")
        RecordingService.working(this)
    }

    // ---- Pill states ------------------------------------------------------------

    private fun setRecordingLook() {
        holding = false
        recRow.visibility = View.VISIBLE
        statusRow.visibility = View.GONE
        pillBg.setStroke(dp(2), Theme.RED)
        recDot.animate().cancel()
        recDot.alpha = 1f
        pulseDot()
    }

    private fun pulseDot() {
        if (recRow.visibility != View.VISIBLE || statusRow.visibility == View.VISIBLE || dictation?.isRecording != true) return
        recDot.animate().alpha(if (recDot.alpha > 0.6f) 0.25f else 1f).setDuration(700)
            .withEndAction { pulseDot() }.start()
    }

    private fun setStatus(working: Boolean, label: String, ok: Boolean = true, widthDp: Int = COMPACT_W) {
        recRow.visibility = View.GONE
        recDot.animate().cancel()
        statusRow.visibility = View.VISIBLE
        pillBg.setStroke(dp(1), 0x26FFFFFF)
        statusIcon.visibility = if (working) View.GONE else View.VISIBLE
        statusIcon.setImageResource(if (ok) R.drawable.ic_check else R.drawable.ic_close)
        statusIcon.imageTintList = android.content.res.ColorStateList.valueOf(if (ok) Theme.GREEN else Theme.CREAM_DIM)
        statusText.text = label
        ring.visibility = if (working) View.VISIBLE else View.GONE
        if (pill.visibility != View.VISIBLE) { bubble.visibility = View.GONE; pill.visibility = View.VISIBLE }
        resizePill(widthDp)
    }

    /** Smoothly change the pill's width (it shrinks into the compact capsule after ✓). */
    private fun resizePill(toDp: Int) {
        val lp = pill.layoutParams
        val to = dp(toDp)
        if (lp.width == to) return
        pillAnim?.cancel()
        pillAnim = android.animation.ValueAnimator.ofInt(lp.width, to).apply {
            duration = 280
            interpolator = android.view.animation.DecelerateInterpolator(2f)
            addUpdateListener { pill.layoutParams = pill.layoutParams.apply { width = it.animatedValue as Int } }
            start()
        }
    }
    private var pillAnim: android.animation.ValueAnimator? = null

    /** Show the outcome briefly, then go back to the button (which hides if no box is focused). */
    private fun confirm(label: String, ok: Boolean = true) {
        setStatus(working = false, label, ok, if (label.length > 16) 272 else COMPACT_W)
        holding = true
        main.postDelayed({
            holding = false
            if (!running) return@postDelayed
            showBubble()
            if (!keyboardVisible()) { main.removeCallbacks(hideRunnable); main.postDelayed(hideRunnable, 400) }
        }, CONFIRM_MS)
    }

    private val tick = object : Runnable {
        override fun run() {
            val used = dictation?.elapsedSeconds ?: 0
            clock.text = "${mmss(used)} / ${mmss(VoiceDictation.MAX_SECONDS)}"
            main.postDelayed(this, 250)
        }
    }
    private fun startTicking() { main.removeCallbacks(tick); tick.run() }
    private fun stopTicking() = main.removeCallbacks(tick)
    private fun mmss(s: Int) = "%d:%02d".format(s / 60, s % 60)

    private fun finished(r: VoiceDictation.Result) {
        RecordingService.stop(this)
        val text = r.text
        if (text == null) {
            Notify.failed(this, r.audio)
            Notify.buzz(this, double = true)
            if (running) confirm("Saved · open Utter to retry", ok = false)
            return
        }
        if (text.isBlank()) {
            if (r.capped) Notify.buzz(this, double = true)
            if (running) confirm("Didn't catch that", ok = false)
            return
        }
        // Type into whatever box is selected now (you may have switched apps while recording).
        val node = if (running) focusedEditable() ?: target?.takeIf { it.refresh() && it.isFocused } else null
        val app = node?.packageName?.toString()?.let { appLabel(it) } ?: ""
        History.add(this, text, app)
        val typed = node != null && insert(node, text)
        if (!typed) {
            val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cb.setPrimaryClip(ClipData.newPlainText("Utter", text))
            Notify.copied(this, text)
            if (running) showCopyPopup(text)
        }
        Notify.buzz(this, double = r.capped)
        if (running) confirm(when {
            r.capped && typed -> "Pasted · 10 min max, tap to go on"
            r.capped -> "Copied · 10 min max, tap to go on"
            typed -> "Pasted"
            else -> "Copied"
        })
    }

    /** Types `text` at the cursor (replacing any selection). Falls back to paste. */
    private fun insert(node: AccessibilityNodeInfo, text: String): Boolean {
        val current = if (node.isShowingHintText) "" else node.text?.toString() ?: ""
        var s = node.textSelectionStart
        var e = node.textSelectionEnd
        if (s < 0 || e < 0 || s > current.length || e > current.length) { s = current.length; e = current.length }
        val before = current.substring(0, min(s, e))
        val after = current.substring(max(s, e))
        val sep = if (before.isNotEmpty() && !before.last().isWhitespace()) " " else ""
        val newText = before + sep + text + after
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, newText)
        })
        if (ok) {
            val c = before.length + sep.length + text.length
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, c)
                putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, c)
            })
            return true
        }
        // Some apps (web views, custom editors) ignore SET_TEXT; paste instead.
        val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cb.setPrimaryClip(ClipData.newPlainText("Utter", text))
        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    // ---- Couldn't type it in: show the words with a Copy button ----------------

    private var popup: View? = null
    private val dismissPopup = Runnable { closePopup() }

    private fun closePopup() {
        popup?.let { try { wm.removeView(it) } catch (_: Exception) {} }
        popup = null
    }

    private fun showCopyPopup(text: String) {
        closePopup()
        // The text is already on the clipboard (copied by the caller); this just shows it.
        val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        val view = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(12))
            background = GradientDrawable().apply { setColor(Theme.CAPSULE); cornerRadius = dp(20).toFloat(); setStroke(dp(1), 0x26FFFFFF) }
            elevation = dp(8).toFloat()
            addView(android.widget.TextView(context).apply {
                this.text = "No text box to type into, so it's copied. Paste it anywhere:"
                textSize = 13f; setTextColor(Theme.CREAM_DIM); typeface = Theme.sans(context, 500)
            })
            addView(android.widget.TextView(context).apply {
                this.text = text
                textSize = 16f; setTextColor(Theme.CREAM); maxLines = 5; typeface = Theme.sans(context, 400)
                setLineSpacing(0f, 1.15f)
                ellipsize = android.text.TextUtils.TruncateAt.END
                setPadding(0, dp(6), 0, dp(8))
            })
            val buttons = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.END }
            buttons.addView(android.widget.TextView(context).apply {
                this.text = "Close"; textSize = 15f; setTextColor(Theme.CREAM_DIM); typeface = Theme.sans(context, 600)
                setPadding(dp(14), dp(8), dp(14), dp(8)); setOnClickListener { closePopup() }
            })
            buttons.addView(android.widget.TextView(context).apply {
                this.text = "Copy"; textSize = 15f; setTextColor(0xFF111111.toInt())
                typeface = Theme.sans(context, 700)
                background = GradientDrawable().apply { setColor(Theme.CREAM); cornerRadius = dp(18).toFloat() }
                setPadding(dp(18), dp(8), dp(18), dp(8))
                setOnClickListener {
                    cb.setPrimaryClip(ClipData.newPlainText("Utter", text))
                    toast("Copied")
                    closePopup()
                }
            })
            addView(buttons)
        }
        val lp = WindowManager.LayoutParams(
            resources.displayMetrics.widthPixels - dp(32), WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL; y = dp(96) }
        try { wm.addView(view, lp); popup = view } catch (_: Exception) { toast("Copied. Long-press a text box and tap Paste.") }
        main.removeCallbacks(dismissPopup)
        main.postDelayed(dismissPopup, 15_000)
    }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}

/**
 * Bars that follow your voice. Takes the level in dBFS and maps roughly -55..-22 dB onto the
 * full height, so normal speech fills most of it; peaks jump up and fall back smoothly.
 */
class WaveView(ctx: Context) : View(ctx) {
    private val levels = FloatArray(28)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Theme.CREAM }
    private val rect = RectF()
    private var last = 0f

    fun reset() { levels.fill(0f); last = 0f; invalidate() }

    fun push(db: Float) {
        val target = ((db + 55f) / 33f).coerceIn(0f, 1f)
        // Fast attack, gentle release.
        last = if (target > last) target else last * 0.6f + target * 0.4f
        System.arraycopy(levels, 1, levels, 0, levels.size - 1)
        levels[levels.size - 1] = Math.pow(last.toDouble(), 0.75).toFloat()
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        val n = levels.size
        val barW = width / (n * 1.75f)
        val gap = (width - barW * n) / (n - 1)
        for (i in 0 until n) {
            val h = max(barW, levels[i] * height)
            val x = i * (barW + gap)
            paint.alpha = (110 + 145 * i / (n - 1))   // older bars fade a little
            rect.set(x, (height - h) / 2, x + barW, (height + h) / 2)
            c.drawRoundRect(rect, barW / 2, barW / 2, paint)
        }
    }
}

/**
 * Small loading ring: a faint full circle with a short cream arc turning at a slow, constant
 * speed (one turn every 1.2 s). No pulsing, no changing arc length, no blinking.
 */
class CalmRing(ctx: Context) : View(ctx) {
    private val stroke = 2f * ctx.resources.displayMetrics.density
    private val track = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = stroke; color = 0x33FAF5E8 }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = stroke; color = Theme.CREAM; strokeCap = Paint.Cap.ROUND
    }
    private val rect = RectF()

    override fun onDraw(c: Canvas) {
        val h = stroke / 2
        rect.set(h, h, width - h, height - h)
        c.drawOval(rect, track)
        val angle = (System.currentTimeMillis() % 1200L) / 1200f * 360f
        c.drawArc(rect, angle, 90f, false, arc)
        if (visibility == VISIBLE && isAttachedToWindow) postInvalidateOnAnimation()
    }
}
