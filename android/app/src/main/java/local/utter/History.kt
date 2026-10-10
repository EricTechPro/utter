package local.utter

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class Entry(val time: Long, val text: String, val app: String)

/** Past dictations, newest first, kept in SharedPreferences (last 200). */
object History {
    private const val PREFS = "utter"
    private const val KEY = "history"

    fun all(ctx: Context): List<Entry> {
        val raw = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, "[]") ?: "[]"
        val arr = JSONArray(raw)
        return (0 until arr.length()).map {
            val o = arr.getJSONObject(it)
            Entry(o.getLong("time"), o.getString("text"), o.optString("app"))
        }
    }

    fun add(ctx: Context, text: String, app: String) {
        val list = listOf(Entry(System.currentTimeMillis(), text, app)) + all(ctx).take(199)
        val arr = JSONArray()
        list.forEach { arr.put(JSONObject().put("time", it.time).put("text", it.text).put("app", it.app)) }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, arr.toString()).apply()
    }

    fun totalWords(ctx: Context): Int = all(ctx).sumOf { e -> e.text.split(Regex("\\s+")).count { it.isNotBlank() } }
}
