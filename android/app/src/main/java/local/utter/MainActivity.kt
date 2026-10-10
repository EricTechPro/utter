package local.utter

import android.Manifest
import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.text.format.DateFormat
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

/**
 * Setup + history. Two steps: allow the microphone, then turn on Utter in
 * Accessibility (sideloaded apps first need "Allow restricted settings").
 */
class MainActivity : Activity() {
    private val cream = 0xFFF7F5F1.toInt()
    private val ink = 0xFF1A1A1A.toInt()
    private val grey = 0xFF6B6B6B.toInt()
    private lateinit var list: LinearLayout

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        render()
    }

    private val micOK get() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private val a11yOK: Boolean
        get() {
            val enabled = Settings.Secure.getString(contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: ""
            return enabled.split(':').any { it.startsWith("$packageName/") }
        }

    private fun render() {
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(48), dp(22), dp(32))
        }

        col.addView(text("Utter", 34f, bold = true))
        col.addView(text("Tap any text box, then tap the blue button to talk.", 16f, color = grey), margins(top = 4, bottom = 20))

        col.addView(step(1, "Microphone", "So Utter can hear you.", micOK, "Allow") {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        })
        col.addView(step(2, "Turn on Utter", "Settings → Accessibility → Utter voice typing → On. " +
                "If it's greyed out: open App info for Utter, tap ⋮, then \"Allow restricted settings\".",
            a11yOK, "Open settings") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        })
        if (!a11yOK) {
            col.addView(Button(this).apply {
                text = "Open App info (for restricted settings)"
                isAllCaps = false
                setOnClickListener {
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                }
            }, margins(bottom = 8))
        }

        col.addView(text("Try it", 18f, bold = true), margins(top = 18, bottom = 6))
        col.addView(EditText(this).apply {
            hint = "Tap here, then tap the blue button"
            textSize = 16f
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = card()
        })

        // History, like the Mac app: word counts, then past results grouped by day.
        col.addView(text("History", 22f, bold = true), margins(top = 28, bottom = 10))
        val stats = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val items = History.all(this)
        stats.addView(stat(History.totalWords(this), "total words"), LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        stats.addView(stat(History.todayWords(this), "today"), LinearLayout.LayoutParams(0, -2, 1f).apply { marginEnd = dp(8) })
        stats.addView(stat(items.size, "dictations"), LinearLayout.LayoutParams(0, -2, 1f))
        col.addView(stats, margins(bottom = 14))

        list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        if (items.isEmpty()) list.addView(text("No dictations yet. Tap a text box, then the blue button.", 15f, color = grey))
        var lastDay = ""
        items.take(200).forEach { e ->
            val day = dayLabel(e.time)
            if (day != lastDay) {
                list.addView(text(day.uppercase(), 13f, color = grey, bold = true), margins(top = 10, bottom = 6))
                lastDay = day
            }
            list.addView(row(e), margins(bottom = 8))
        }
        col.addView(list)

        setContentView(ScrollView(this).apply {
            setBackgroundColor(cream)
            addView(col)
        })
    }

    private fun step(n: Int, title: String, detail: String, ok: Boolean, button: String, action: () -> Unit): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(14), dp(14), dp(14))
            background = card(if (ok) 0xFF34C759.toInt() else 0x14000000)
        }
        row.addView(TextView(this).apply {
            text = if (ok) "✓" else "$n"
            gravity = Gravity.CENTER
            textSize = 15f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (ok) Color.WHITE else ink)
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(if (ok) 0xFF34C759.toInt() else 0x14000000)
            }
        }, LinearLayout.LayoutParams(dp(32), dp(32)))
        val texts = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, dp(8), 0)
            addView(text(title, 16f, bold = true))
            addView(text(detail, 13f, color = grey))
        }
        row.addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        if (ok) {
            row.addView(text("Done", 14f, color = 0xFF34C759.toInt(), bold = true))
        } else {
            row.addView(Button(this).apply {
                text = button
                isAllCaps = false
                setTextColor(Color.WHITE)
                background = GradientDrawable().apply { setColor(BubbleService.BLUE); cornerRadius = dp(20).toFloat() }
                setPadding(dp(14), 0, dp(14), 0)
                setOnClickListener { action() }
            }, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(40)))
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(row)
            setPadding(0, 0, 0, dp(10))
        }
    }

    private fun stat(value: Int, label: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(12), dp(14), dp(12))
        background = card()
        addView(text("%,d".format(value), 24f, bold = true).apply { typeface = Typeface.SERIF })
        addView(text(label, 13f, color = grey))
    }

    private fun dayLabel(t: Long): String {
        val today = DateFormat.format("yyyyMMdd", System.currentTimeMillis()).toString()
        val yesterday = DateFormat.format("yyyyMMdd", System.currentTimeMillis() - 86_400_000).toString()
        return when (DateFormat.format("yyyyMMdd", t).toString()) {
            today -> "Today"
            yesterday -> "Yesterday"
            else -> DateFormat.format("EEEE, MMM d", t).toString()
        }
    }

    private fun row(e: Entry): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(14), dp(12), dp(14), dp(10))
        background = card()
        val time = DateFormat.format("h:mm a", e.time).toString()
        addView(text(if (e.app.isNotEmpty()) "$time · ${e.app}" else time, 13f, color = grey))
        addView(text(e.text, 16f).apply { setTextIsSelectable(true) },
            LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(4) })
        val actions = LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
        }
        actions.addView(smallButton("Copy") {
            val cb = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cb.setPrimaryClip(ClipData.newPlainText("Utter", e.text))
            Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
        })
        actions.addView(smallButton("Delete") { History.delete(this@MainActivity, e.time); render() })
        addView(actions, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(6) })
    }

    private fun smallButton(label: String, action: () -> Unit) = TextView(this).apply {
        text = label
        textSize = 14f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(if (label == "Delete") grey else BubbleService.BLUE)
        setPadding(dp(12), dp(6), dp(12), dp(6))
        setOnClickListener { action() }
    }

    private fun card(stroke: Int = 0x14000000) = GradientDrawable().apply {
        setColor(0xFFFDFCFA.toInt())
        cornerRadius = dp(14).toFloat()
        setStroke(dp(1), stroke)
    }

    private fun text(s: String, size: Float, color: Int = ink, bold: Boolean = false) = TextView(this).apply {
        text = s
        textSize = size
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun margins(top: Int = 0, bottom: Int = 0) =
        LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top); bottomMargin = dp(bottom) }
}
