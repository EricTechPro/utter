package local.utter

import android.content.Context
import android.graphics.Typeface

/**
 * Colours and type shared by the app screen and the floating pill, matched to the Mac app:
 * warm near-black surfaces, cream text, red only while recording.
 * Figtree for text, EB Garamond for titles and big numbers (both bundled, SIL OFL).
 */
object Theme {
    const val BG = 0xFF0E0D0C.toInt()
    const val SURFACE = 0xFF1A1917.toInt()
    const val SURFACE_HI = 0xFF262421.toInt()
    const val LINE = 0x1FFAF5E8          // cream at 12%
    const val CREAM = 0xFFFAF5E8.toInt()
    const val CREAM_DIM = 0xA6FAF5E8.toInt() // 65%: secondary text, ~7:1 on BG
    const val CREAM_FAINT = 0x66FAF5E8      // 40%: hints
    const val RED = 0xFFFF453A.toInt()
    const val GREEN = 0xFF32D74B.toInt()
    /** The floating capsule: Mac dock black at 94%. */
    const val CAPSULE = 0xF0121110.toInt()

    private val cache = HashMap<String, Typeface>()

    fun sans(ctx: Context, weight: Int = 400): Typeface = font(ctx, "Figtree", weight)
    fun serif(ctx: Context, weight: Int = 500): Typeface = font(ctx, "EBGaramond", weight)

    private fun font(ctx: Context, name: String, weight: Int): Typeface = synchronized(cache) {
        cache.getOrPut("$name$weight") {
            try {
                Typeface.Builder(ctx.assets, "fonts/$name.ttf")
                    .setFontVariationSettings("'wght' $weight")
                    .build()
            } catch (_: Exception) {
                Typeface.create(Typeface.DEFAULT, if (weight >= 600) Typeface.BOLD else Typeface.NORMAL)
            }
        }
    }
}
