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
 * Shows a small blue mic button whenever a text box has focus, in any app.
 * Tap it to talk; the button grows into a pill with ✕ (discard), a live waveform,
 * and ✓ (type it in). Drag the button anywhere; it snaps to the nearest edge.
 */
class BubbleService : AccessibilityService() {
    companion object {
        const val BLUE = 0xFF2563EB.toInt()
        var running = false
            private set
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var wm: WindowManager
    private lateinit var params: WindowManager.LayoutParams
    private lateinit var root: FrameLayout
    private lateinit var bubble: FrameLayout
    private lateinit var pill: LinearLayout
    private lateinit var wave: WaveView
    private var shown = false
    private var target: AccessibilityNodeInfo? = null
    private var dictation: Dictation? = null
    private val hideRunnable = Runnable { if (dictation?.isActive != true) hide() }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onServiceConnected() {
        running = true
        wm = getSystemService(WINDOW_SERVICE) as WindowManager
        buildViews()
        dictation = Dictation(
            this,
            onLevel = { wave.push(it) },
            onPartial = { },
            onDone = { text -> main.post { finished(text) } },
            onError = { msg -> main.post { toast(msg); showBubble() } },
        )
    }

    override fun onDestroy() {
        running = false
        dictation?.cancel()
        hide()
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (dictation?.isActive == true) return
        val node = focusedEditable()
        if (node != null) {
            main.removeCallbacks(hideRunnable)
            target = node
            show()
        } else {
            main.removeCallbacks(hideRunnable)
            main.postDelayed(hideRunnable, 400)
        }
    }

    private fun focusedEditable(): AccessibilityNodeInfo? {
        val candidates = listOfNotNull(rootInActiveWindow) + (windows?.mapNotNull { it.root } ?: emptyList())
        for (r in candidates) {
            val f = r.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: continue
            if (f.isEditable && !f.isPassword && f.packageName != packageName + ".overlay") return f
        }
        return null
    }

    // ---- Views ----------------------------------------------------------------

    private fun buildViews() {
        root = FrameLayout(this)

        bubble = FrameLayout(this).apply {
            background = GradientDrawable().apply { setColor(BLUE); cornerRadius = dp(16).toFloat() }
            elevation = dp(6).toFloat()
            addView(ImageView(context).apply { setImageResource(R.drawable.ic_wave) },
                FrameLayout.LayoutParams(dp(26), dp(26), Gravity.CENTER))
        }
        root.addView(bubble, FrameLayout.LayoutParams(dp(52), dp(52)))

        val close = ImageView(this).apply {
            setImageResource(R.drawable.ic_close)
            setPadding(dp(10), dp(10), dp(10), dp(10))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0x33FFFFFF) }
            setOnClickListener { cancel() }
        }
        wave = WaveView(this)
        val done = ImageView(this).apply {
            setImageResource(R.drawable.ic_check)
            setPadding(dp(9), dp(9), dp(9), dp(9))
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.WHITE) }
            setOnClickListener { finish() }
        }
        pill = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            background = GradientDrawable().apply { setColor(BLUE); cornerRadius = dp(28).toFloat() }
            elevation = dp(6).toFloat()
            addView(close, LinearLayout.LayoutParams(dp(40), dp(40)))
            addView(wave, LinearLayout.LayoutParams(0, dp(32), 1f).apply { marginStart = dp(10); marginEnd = dp(10) })
            addView(done, LinearLayout.LayoutParams(dp(40), dp(40)))
            visibility = View.GONE
        }
        root.addView(pill, FrameLayout.LayoutParams(dp(220), dp(56)))

        val prefs = getSharedPreferences("utter", MODE_PRIVATE)
        val screenW = resources.displayMetrics.widthPixels
        params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt("x", screenW - dp(52) - dp(12))
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
        params.x = if (params.x + dp(26) < w / 2) dp(12) else w - dp(52) - dp(12)
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
        pill.visibility = View.GONE
        bubble.visibility = View.VISIBLE
        val prefs = getSharedPreferences("utter", MODE_PRIVATE)
        params.x = prefs.getInt("x", params.x)
        if (shown) wm.updateViewLayout(root, params)
    }

    private fun showPill() {
        bubble.visibility = View.GONE
        pill.visibility = View.VISIBLE
        wave.reset()
        // Keep the pill on screen when the button sits on the right edge.
        val w = resources.displayMetrics.widthPixels
        params.x = min(params.x, w - dp(220) - dp(12)).coerceAtLeast(dp(12))
        if (shown) wm.updateViewLayout(root, params)
    }

    // ---- Dictation ------------------------------------------------------------

    private fun start() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            toast("Open Utter and allow the microphone first.")
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        target = focusedEditable() ?: target
        showPill()
        dictation?.start()
    }

    private fun finish() {
        pill.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        wave.thinking = true
        dictation?.finish()
    }

    private fun cancel() {
        dictation?.cancel()
        showBubble()
    }

    private fun finished(text: String) {
        wave.thinking = false
        showBubble()
        if (text.isBlank()) { toast("Didn't catch that. Try again."); return }
        val node = target?.also { it.refresh() } ?: focusedEditable()
        val app = node?.packageName?.toString()?.let { appLabel(it) } ?: ""
        History.add(this, text, app)
        if (node == null || !insert(node, text)) {
            val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cb.setPrimaryClip(ClipData.newPlainText("Utter", text))
            toast("Copied. Long-press the text box and tap Paste.")
        }
    }

    /** Types `text` at the cursor (replacing any selection). Falls back to paste. */
    private fun insert(node: AccessibilityNodeInfo, text: String): Boolean {
        val current = if (Build.VERSION.SDK_INT >= 26 && node.isShowingHintText) "" else node.text?.toString() ?: ""
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

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_SHORT).show()
}

/** White bars that follow your voice; pulses gently while the words are being finished. */
class WaveView(ctx: Context) : View(ctx) {
    private val levels = FloatArray(24)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val rect = RectF()
    var thinking = false
        set(v) { field = v; invalidate() }

    fun reset() { levels.fill(0f); invalidate() }

    fun push(rmsDb: Float) {
        System.arraycopy(levels, 1, levels, 0, levels.size - 1)
        levels[levels.size - 1] = ((rmsDb + 2f) / 12f).coerceIn(0f, 1f)
        invalidate()
    }

    override fun onDraw(c: Canvas) {
        val n = levels.size
        val barW = width / (n * 1.8f)
        val gap = (width - barW * n) / (n - 1)
        val t = System.currentTimeMillis() / 180.0
        for (i in 0 until n) {
            val v = if (thinking) (0.25f + 0.2f * kotlin.math.sin(t + i * 0.5).toFloat()) else levels[i]
            val h = max(barW, v * height)
            val x = i * (barW + gap)
            rect.set(x, (height - h) / 2, x + barW, (height + h) / 2)
            c.drawRoundRect(rect, barW / 2, barW / 2, paint)
        }
        if (thinking) postInvalidateOnAnimation()
    }
}
