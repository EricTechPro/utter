package local.utter

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.LayerDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.DateFormat
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File

/**
 * Setup + history, in the Mac app's dark look. Three steps: allow the microphone and
 * notifications, turn on Utter in Accessibility (sideloaded apps first need "Allow restricted
 * settings"), download the voice model. Below: a box to try it, unfinished recordings, history.
 */
class MainActivity : Activity() {
    companion object {
        /** Name of a saved recording (in [Recordings.dir]) to transcribe again. */
        const val EXTRA_RETRY = "retry"
        private const val MODEL_MB = 60

        // Process-wide, so rotating the screen or reopening from a notification can't start a
        // second download or a second retry of the same recording.
        @Volatile private var downloading: Int? = null
        private val retrying: MutableSet<String> = java.util.concurrent.ConcurrentHashMap.newKeySet()
        /** The screen currently showing, for progress updates from background work. */
        @Volatile private var shown: MainActivity? = null
        private val ui = android.os.Handler(android.os.Looper.getMainLooper())
    }

    override fun onPause() { if (shown === this) shown = null; super.onPause() }

    // Only these change while the model downloads; the rest of the screen is left alone.
    private var progressBar: ProgressBar? = null
    private var progressLabel: TextView? = null

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        shown = this
        render()
        intent?.getStringExtra(EXTRA_RETRY)?.let { name ->
            intent.removeExtra(EXTRA_RETRY)
            retry(File(Recordings.dir(this), File(name).name))
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        render()
    }

    // ---- Actions -----------------------------------------------------------------

    private fun downloadModel() {
        synchronized(retrying) { if (downloading != null) return; downloading = 0 }
        render()
        val app = applicationContext
        Thread {
            var lastPct = -1
            var lastAt = 0L
            val ok = try {
                Whisper.download(app) { p ->
                    // At most ~5 updates a second, and only when the percentage moves.
                    val pct = (p * 100).toInt()
                    val now = System.currentTimeMillis()
                    if (pct != lastPct && (now - lastAt > 200 || pct == 100)) {
                        lastPct = pct; lastAt = now
                        ui.post { downloading = pct; shown?.showProgress(pct) }
                    }
                }
                true
            } catch (e: Exception) { false }
            ui.post {
                downloading = null
                if (!ok) Toast.makeText(app, "Download failed. Check your internet and try again.", Toast.LENGTH_LONG).show()
                shown?.render()
            }
        }.start()
    }

    private fun showProgress(pct: Int) {
        progressBar?.progress = pct
        progressLabel?.text = "$pct%  ·  ${MODEL_MB * pct / 100} of $MODEL_MB MB"
    }

    /** Transcribes a saved recording again; the text goes to History and the clipboard. */
    private fun retry(file: File) {
        if (!file.exists() || !retrying.add(file.name)) return
        render()
        val app = applicationContext
        Thread {
            val t = ChunkTranscriber(app)
            val text = try {
                val chunker = Chunker(VoiceDictation.RATE) { t.submit(it) }
                readWavPieces(file) { chunker.append(it) }
                chunker.flush()
                t.finish()
            } catch (e: Throwable) { t.abort(); null }
            ui.post {
                when {
                    text == null -> Toast.makeText(app, "Still couldn't transcribe it. The audio is kept; try again later.", Toast.LENGTH_LONG).show()
                    text.isBlank() -> {
                        // Nothing to recover: don't keep it in Unfinished forever.
                        Recordings.delete(file)
                        Toast.makeText(app, "No speech found in that recording, so it was removed.", Toast.LENGTH_LONG).show()
                    }
                    else -> {
                        History.add(app, text, "Recovered recording")
                        (app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
                            .setPrimaryClip(ClipData.newPlainText("Utter", text))
                        Recordings.delete(file)
                        Toast.makeText(app, "Done. It's copied and in History.", Toast.LENGTH_LONG).show()
                    }
                }
                retrying.remove(file.name)
                shown?.render()
            }
        }.start()
    }

    private fun copy(text: String) {
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("Utter", text))
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    // ---- State -------------------------------------------------------------------

    private val micOK get() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    private val notifyOK get() = Build.VERSION.SDK_INT < 33 ||
        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private val a11yOK: Boolean
        get() {
            val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
            return enabled.split(':').any { it.startsWith("$packageName/") }
        }

    // ---- Screen ------------------------------------------------------------------

    private fun render() {
        progressBar = null
        progressLabel = null
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(96))
        }

        // Header: the app mark and name, like the Mac app's window.
        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(ImageView(context).apply {
                setImageResource(R.mipmap.ic_launcher)
                clipToOutline = true
                outlineProvider = object : android.view.ViewOutlineProvider() {
                    override fun getOutline(v: View, o: android.graphics.Outline) { o.setRoundRect(0, 0, v.width, v.height, dp(12).toFloat()) }
                }
            }, LinearLayout.LayoutParams(dp(44), dp(44)))
            addView(text("Utter", 34f, Theme.CREAM, serif = true), LinearLayout.LayoutParams(-2, -2).apply { marginStart = dp(14) })
        }
        col.addView(head, margins(top = 12, bottom = 14))
        col.addView(text("Tap the mic button in any text box. Utter records like a voice recorder, " +
                "then types your words in. Everything stays on this phone.", 16f, Theme.CREAM_DIM).apply {
            setLineSpacing(0f, 1.25f)
        }, margins(bottom = 32))

        // Setup: one grouped panel, three numbered rows.
        val ready = micOK && notifyOK && a11yOK && Whisper.hasModel(this)
        col.addView(heading(if (ready) "All set" else "Set up"), margins(bottom = 12))
        val setup = panel()
        setup.addView(step(1, "Microphone & notifications",
            "So Utter can hear you, and keep recording with the screen off.",
            micOK && notifyOK, "Allow") {
            val perms = mutableListOf(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) perms += Manifest.permission.POST_NOTIFICATIONS
            requestPermissions(perms.toTypedArray(), 1)
        })
        setup.addView(divider())
        setup.addView(step(2, "Turn on Utter",
            "Settings → Accessibility → Utter voice typing → On. Greyed out? Open App info, tap ⋮, " +
                "then Allow restricted settings.",
            a11yOK, "Open settings", secondary = if (!a11yOK) "App info" to {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
            } else null) {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        })
        setup.addView(divider())
        val dl = downloading
        setup.addView(step(3, "Voice model",
            if (dl != null) "Downloading. Keep this screen open."
            else "One-time download, about $MODEL_MB MB. After that, speech turns into text on your phone.",
            Whisper.hasModel(this), if (dl != null) null else "Download",
            progress = dl) { downloadModel() })
        col.addView(setup, margins(bottom = 32))

        // Try it.
        col.addView(heading("Try it"), margins(bottom = 12))
        col.addView(EditText(this).apply {
            hint = "Tap here, then the mic button"
            textSize = 16f
            setTextColor(Theme.CREAM)
            setHintTextColor(Theme.CREAM_FAINT)
            typeface = Theme.sans(context, 400)
            minHeight = dp(56)
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = GradientDrawable().apply {
                setColor(Theme.SURFACE); cornerRadius = dp(14).toFloat(); setStroke(dp(1), Theme.LINE)
            }
        }, margins(bottom = 32))

        // Recordings that couldn't be transcribed: the audio is kept until it works.
        val unfinished = Recordings.unfinished(this, except = VoiceDictation.currentFile)
        if (unfinished.isNotEmpty()) {
            col.addView(heading("Unfinished recordings"), margins(bottom = 4))
            col.addView(text("Transcription didn't finish. The audio is safe; retry when you like.", 14f, Theme.CREAM_DIM), margins(bottom = 12))
            val p = panel()
            unfinished.forEachIndexed { i, f ->
                if (i > 0) p.addView(divider())
                p.addView(unfinishedRow(f))
            }
            col.addView(p, margins(bottom = 32))
        }

        // History, like the Mac app: word counts, then past results grouped by day.
        val items = History.all(this)
        col.addView(heading("History"), margins(bottom = 6))
        stats = text("", 14f, Theme.CREAM_DIM).apply { fontFeatureSettings = "tnum" }
        updateStats()
        col.addView(stats, margins(bottom = 8))
        if (items.isEmpty()) {
            col.addView(text("Nothing yet. Your dictations show up here, newest first.", 15f, Theme.CREAM_DIM), margins(top = 8))
        }
        var lastDay = ""
        items.take(100).forEach { e ->
            val day = dayLabel(e.time)
            val first = day != lastDay
            if (first) {
                col.addView(text(day, 13f, Theme.CREAM_DIM, weight = 600), margins(top = 20, bottom = 4))
                lastDay = day
            }
            // Divider and row live in one container, so deleting removes both in place.
            col.addView(LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                if (!first) addView(divider())
                addView(historyRow(e, this))
            }, LinearLayout.LayoutParams(-1, -2))
        }

        val oldScroll = scrollView?.scrollY ?: 0
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Theme.BG)
            isFillViewport = true
            addView(col)
            // Edge to edge: keep content clear of the status and navigation bars.
            setOnApplyWindowInsetsListener { v, insets ->
                val bars = if (Build.VERSION.SDK_INT >= 30) insets.getInsets(WindowInsets.Type.systemBars())
                    .let { intArrayOf(it.top, it.bottom) }
                else @Suppress("DEPRECATION") intArrayOf(insets.systemWindowInsetTop, insets.systemWindowInsetBottom)
                v.setPadding(0, bars[0], 0, bars[1])
                insets
            }
        }
        scrollView = scroll
        // A snackbar at the bottom for "Deleted · Undo".
        snackbar = buildSnackbar()
        setContentView(android.widget.FrameLayout(this).apply {
            addView(scroll, android.widget.FrameLayout.LayoutParams(-1, -1))
            addView(snackbar, android.widget.FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM).apply {
                leftMargin = dp(16); rightMargin = dp(16); bottomMargin = dp(16)
            })
        })
        // Keep the reading position when the screen refreshes (e.g. coming back to the app).
        scroll.post { scroll.scrollTo(0, oldScroll) }
    }

    // ---- History: copy, delete in place, undo -------------------------------------

    private var scrollView: ScrollView? = null
    private var stats: TextView? = null
    private var snackbar: LinearLayout? = null
    private var snackText: TextView? = null
    private var undo: (() -> Unit)? = null
    private val hideSnack = Runnable { snackbar?.animate()?.alpha(0f)?.translationY(dp(16).toFloat())?.setDuration(200)?.withEndAction { snackbar?.visibility = View.GONE; undo = null } }

    private fun updateStats() {
        val items = History.all(this)
        val dayStart = java.util.Calendar.getInstance().apply {
            set(java.util.Calendar.HOUR_OF_DAY, 0); set(java.util.Calendar.MINUTE, 0)
            set(java.util.Calendar.SECOND, 0); set(java.util.Calendar.MILLISECOND, 0)
        }.timeInMillis
        stats?.text = "%,d words  ·  %,d today  ·  %,d dictations".format(
            items.sumOf { History.words(it.text) }, items.filter { it.time >= dayStart }.sumOf { History.words(it.text) }, items.size)
    }

    private fun buildSnackbar() = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16), dp(4), dp(4), dp(4))
        minimumHeight = dp(52)
        elevation = dp(6).toFloat()
        background = GradientDrawable().apply { setColor(Theme.SURFACE_HI); cornerRadius = dp(14).toFloat(); setStroke(dp(1), Theme.LINE) }
        val label = text("Deleted", 15f, Theme.CREAM)
        snackText = label
        addView(label, LinearLayout.LayoutParams(0, -2, 1f))
        addView(textButton("Undo", Theme.CREAM) { undo?.invoke(); undo = null; hideSnack.run() })
        visibility = View.GONE
    }

    private fun showSnack(msg: String, onUndo: () -> Unit) {
        val bar = snackbar ?: return
        undo = onUndo
        snackText?.text = msg
        bar.removeCallbacks(hideSnack)
        bar.visibility = View.VISIBLE
        bar.alpha = 0f; bar.translationY = dp(16).toFloat()
        bar.animate().alpha(1f).translationY(0f).setDuration(200).start()
        bar.postDelayed(hideSnack, 4500)
    }

    /** Collapse a row in place (no jump), then offer Undo. */
    private fun deleteItem(container: View, e: Entry) {
        val parent = container.parent as? LinearLayout ?: return
        val index = parent.indexOfChild(container)
        History.delete(this, e.time)
        updateStats()
        val h = container.height
        android.animation.ValueAnimator.ofFloat(1f, 0f).apply {
            duration = 220
            interpolator = android.view.animation.DecelerateInterpolator()
            addUpdateListener {
                val f = it.animatedValue as Float
                container.alpha = f
                container.layoutParams = container.layoutParams.apply { height = (h * f).toInt().coerceAtLeast(1) }
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(a: android.animation.Animator) { parent.removeView(container) }
            })
            start()
        }
        showSnack("Deleted") {
            History.restore(this, e)
            updateStats()
            container.alpha = 0f
            container.layoutParams = container.layoutParams.apply { height = LinearLayout.LayoutParams.WRAP_CONTENT }
            if (container.parent == null) parent.addView(container, index.coerceAtMost(parent.childCount))
            container.animate().alpha(1f).setDuration(200).start()
        }
    }

    private fun step(
        n: Int, title: String, detail: String, ok: Boolean, button: String?,
        progress: Int? = null, secondary: Pair<String, () -> Unit>? = null, action: () -> Unit,
    ): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }
        row.addView(TextView(this).apply {
            text = if (ok) "" else "$n"
            gravity = Gravity.CENTER
            textSize = 14f
            typeface = Theme.sans(context, 700)
            setTextColor(if (ok) 0xFF0E0D0C.toInt() else Theme.CREAM)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                if (ok) setColor(Theme.GREEN) else { setColor(Theme.SURFACE_HI); setStroke(dp(1), Theme.LINE) }
            }
            if (ok) {
                // Drawn check, not a glyph.
                foreground = getDrawable(R.drawable.ic_check)?.mutate()?.apply { setTint(0xFF0E0D0C.toInt()) }
                foregroundGravity = Gravity.FILL
            }
        }, LinearLayout.LayoutParams(dp(28), dp(28)).apply { topMargin = dp(1) })
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), 0, 0, 0)
            addView(text(title, 16f, if (ok) Theme.CREAM_DIM else Theme.CREAM, weight = 600))
            if (!ok) addView(text(detail, 14f, Theme.CREAM_DIM).apply { setLineSpacing(0f, 1.2f) },
                LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
            if (!ok && progress != null) {
                val bar = ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100
                    this.progress = progress
                    progressDrawable = progressTrack()
                }
                progressBar = bar
                addView(bar, LinearLayout.LayoutParams(-1, dp(6)).apply { topMargin = dp(12) })
                val label = text("$progress%  ·  ${MODEL_MB * progress / 100} of $MODEL_MB MB", 13f, Theme.CREAM_DIM).apply {
                    fontFeatureSettings = "tnum"
                }
                progressLabel = label
                addView(label, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
            }
            if (!ok && button != null) {
                val buttons = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
                buttons.addView(pillButton(button, filled = true, action))
                secondary?.let { (label, act) ->
                    buttons.addView(pillButton(label, filled = false, act), LinearLayout.LayoutParams(-2, dp(44)).apply { marginStart = dp(8) })
                }
                addView(buttons, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(12) })
            }
        }
        row.addView(body, LinearLayout.LayoutParams(0, -2, 1f))
        return row
    }

    private fun progressTrack(): LayerDrawable {
        val track = GradientDrawable().apply { setColor(Theme.SURFACE_HI); cornerRadius = dp(3).toFloat() }
        val fill = ClipDrawable(GradientDrawable().apply { setColor(Theme.CREAM); cornerRadius = dp(3).toFloat() },
            Gravity.START, ClipDrawable.HORIZONTAL)
        return LayerDrawable(arrayOf(track, fill)).apply {
            setId(0, android.R.id.background); setId(1, android.R.id.progress)
        }
    }

    private fun pillButton(label: String, filled: Boolean, action: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 15f
        typeface = Theme.sans(context, 600)
        gravity = Gravity.CENTER
        minHeight = dp(44)
        setPadding(dp(18), 0, dp(18), 0)
        setTextColor(if (filled) 0xFF0E0D0C.toInt() else Theme.CREAM)
        background = android.graphics.drawable.RippleDrawable(ColorStateList.valueOf(0x33FFFFFF),
            GradientDrawable().apply {
                cornerRadius = dp(22).toFloat()
                if (filled) setColor(Theme.CREAM) else { setColor(0); setStroke(dp(1), 0x40FAF5E8) }
            }, null)
        isClickable = true
        setOnClickListener { action() }
    }

    private fun unfinishedRow(f: File): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(10), dp(8), dp(10))
        val secs = ((f.length() - 44) / (VoiceDictation.RATE * 2)).toInt()
        val whenText = DateFormat.format("EEE h:mm a", f.lastModified()).toString()
        val busy = f.name in retrying
        val saved = Recordings.partialText(f).takeIf { it.exists() }?.readText()?.trim()?.replace("\n", " ").orEmpty()
        val top = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(text(whenText, 15f, Theme.CREAM, weight = 500))
                addView(text(if (busy) "Transcribing…" else "${secs / 60}:${"%02d".format(secs % 60)} of audio", 13f, Theme.CREAM_DIM))
            }, LinearLayout.LayoutParams(0, -2, 1f))
            if (!busy) {
                addView(textButton("Retry", Theme.CREAM) { retry(f) })
                addView(textButton("Delete", Theme.CREAM_DIM) { Recordings.delete(f); render() })
            }
        }
        addView(top)
        if (saved.isNotEmpty()) {
            // Text from the chunks that finished before it was cut off.
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                addView(text("Saved so far: " + saved, 14f, Theme.CREAM_DIM).apply {
                    maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END; setLineSpacing(0f, 1.2f)
                }, LinearLayout.LayoutParams(0, -2, 1f))
                addView(copyButton(saved))
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
        }
    }

    private fun historyRow(e: Entry, container: View): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(0, dp(12), 0, dp(2))
        addView(text(DateFormat.format("h:mm a", e.time).toString(), 13f, Theme.CREAM_FAINT))
        addView(text(e.text, 16f, Theme.CREAM).apply { setTextIsSelectable(true); setLineSpacing(0f, 1.25f) },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
        val actions = LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            addView(copyButton(e.text))
            addView(textButton("Delete", Theme.CREAM_DIM) { deleteItem(container, e) })
        }
        addView(actions, LinearLayout.LayoutParams(-1, -2))
    }

    /** Copy icon; turns into a green check for a moment after a tap. */
    private fun copyButton(textToCopy: String) = ImageView(this).apply {
        setImageResource(R.drawable.ic_copy)
        imageTintList = ColorStateList.valueOf(Theme.CREAM)
        contentDescription = "Copy"
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        setPadding(dp(13), dp(13), dp(13), dp(13))
        layoutParams = LinearLayout.LayoutParams(dp(48), dp(48))
        background = android.graphics.drawable.RippleDrawable(ColorStateList.valueOf(0x22FFFFFF), null,
            GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(-1) })
        setOnClickListener {
            copy(textToCopy)
            setImageResource(R.drawable.ic_check)
            imageTintList = ColorStateList.valueOf(Theme.GREEN)
            Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
            postDelayed({
                setImageResource(R.drawable.ic_copy)
                imageTintList = ColorStateList.valueOf(Theme.CREAM)
            }, 1200)
        }
    }

    private fun textButton(label: String, color: Int, action: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 14f
        typeface = Theme.sans(context, 600)
        setTextColor(color)
        gravity = Gravity.CENTER
        minHeight = dp(48)
        minWidth = dp(48)
        setPadding(dp(12), 0, dp(12), 0)
        background = android.graphics.drawable.RippleDrawable(ColorStateList.valueOf(0x22FFFFFF), null,
            GradientDrawable().apply { setColor(-1); cornerRadius = dp(12).toFloat() })
        setOnClickListener { action() }
    }

    private fun panel() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply { setColor(Theme.SURFACE); cornerRadius = dp(16).toFloat() }
    }

    private fun divider() = View(this).apply {
        setBackgroundColor(Theme.LINE)
        layoutParams = LinearLayout.LayoutParams(-1, maxOf(1, dp(1) / 2))
    }

    private fun heading(s: String) = text(s, 22f, Theme.CREAM, serif = true)

    private fun dayLabel(t: Long): String {
        val today = DateFormat.format("yyyyMMdd", System.currentTimeMillis()).toString()
        val yesterday = DateFormat.format("yyyyMMdd", System.currentTimeMillis() - 86_400_000).toString()
        return when (DateFormat.format("yyyyMMdd", t).toString()) {
            today -> "Today"
            yesterday -> "Yesterday"
            else -> DateFormat.format("EEEE, MMM d", t).toString()
        }
    }

    private fun text(s: String, size: Float, color: Int, weight: Int = 400, serif: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        typeface = if (serif) Theme.serif(context, 500) else Theme.sans(context, weight)
    }

    private fun margins(top: Int = 0, bottom: Int = 0) =
        LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top); bottomMargin = dp(bottom) }
}
