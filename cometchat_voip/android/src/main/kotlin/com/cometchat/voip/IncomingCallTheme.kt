package com.cometchat.voip

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * The colours of the ring screen and of the call notifications, set from Dart
 * (`CometChatVoip.setIncomingCallTheme`, or `incomingCallTheme` on the config).
 *
 * Saved on its own, apart from [VoipConfig], because the background message
 * handler calls `init` again on every push that wakes the app, without a
 * theme: an `init` that carries no theme keeps the saved one, and only an
 * explicit clear removes it. The saved form is Android's own
 * (`{"v":1,"mode":"system","light":{…},"dark":{…}}`, colours as `#AARRGGBB`),
 * so the two platforms share one contract.
 *
 * Every colour is optional. A colour the theme leaves out comes from the
 * `cometchat_voip_call_*` resource, except in the light set: the resources are
 * dark (the screen's default look), and a light theme that left, say, the
 * caller name out would get a light-grey name on a white page. A light set
 * fills its gaps from [LIGHT_DEFAULTS] instead.
 */
internal object IncomingCallTheme {

    private const val PREFS = "cometchat_voip_incoming_call_theme"
    private const val KEY = "incomingCallTheme"

    /** The keys of one colour set, in Android's order. */
    val KEYS = listOf(
        "background", "callerName", "subtitle", "avatarBackground", "avatarText",
        "acceptButton", "acceptIcon", "acceptLabel", "declineButton", "declineIcon", "declineLabel"
    )

    /** What a light set uses for a colour it leaves out: the UI Kit's light palette. */
    private val LIGHT_DEFAULTS = mapOf(
        "background" to 0xFFFFFFFF.toInt(),
        "callerName" to 0xFF141414.toInt(),
        "subtitle" to 0xFF727272.toInt(),
        "avatarBackground" to 0xFF6852D6.toInt(),
        "avatarText" to 0xFFFFFFFF.toInt(),
        "acceptButton" to 0xFF09C26F.toInt(),
        "acceptIcon" to 0xFFFFFFFF.toInt(),
        "acceptLabel" to 0xFF727272.toInt(),
        "declineButton" to 0xFFF44649.toInt(),
        "declineIcon" to 0xFFFFFFFF.toInt(),
        "declineLabel" to 0xFF727272.toInt()
    )

    private val RESOURCES = mapOf(
        "background" to R.color.cometchat_voip_call_background,
        "callerName" to R.color.cometchat_voip_call_text,
        "subtitle" to R.color.cometchat_voip_call_text_secondary,
        "avatarBackground" to R.color.cometchat_voip_call_avatar,
        "avatarText" to R.color.cometchat_voip_call_avatar_text,
        "acceptButton" to R.color.cometchat_voip_call_accept,
        "acceptIcon" to R.color.cometchat_voip_call_accept_icon,
        "acceptLabel" to R.color.cometchat_voip_call_accept_label,
        "declineButton" to R.color.cometchat_voip_call_decline,
        "declineIcon" to R.color.cometchat_voip_call_decline_icon,
        "declineLabel" to R.color.cometchat_voip_call_decline_label
    )

    /** A parsed theme. A set is null when the theme leaves it out. */
    data class Theme(val mode: String, val light: Map<String, Int>?, val dark: Map<String, Int>?)

    @Volatile
    private var cached: Theme? = null

    @Volatile
    private var loaded = false

    /** Saves [map] (the Dart `toMap()` form) as the theme, or clears it when null. */
    fun save(context: Context, map: Map<*, *>?) {
        val json = map?.let { toJson(it) }
        val theme = json?.let { parse(it) }
        prefs(context).edit().apply {
            if (theme == null) remove(KEY) else putString(KEY, json.toString())
        }.commit() // Committed: a kill right after a change must not lose it.
        cached = theme
        loaded = true
        Log.d(if (theme == null) "incoming call theme cleared" else "incoming call theme saved (${theme.mode})")
    }

    /** The saved theme, or null. An unreadable one counts as none. */
    fun get(context: Context): Theme? {
        if (!loaded) {
            cached = prefs(context).getString(KEY, null)?.let {
                runCatching { parse(JSONObject(it)) }.getOrNull()
            }
            loaded = true
        }
        return cached
    }

    /** Every colour resolved for [context]'s current light or dark mode. */
    fun resolve(context: Context): Colors {
        val theme = get(context)
        val dark = when (theme?.mode) {
            "light" -> false
            "dark" -> true
            else -> isSystemDark(context)
        }
        val set = if (dark) theme?.dark else theme?.light
        val lightFill = !dark && set != null
        val values = KEYS.associateWith { key ->
            set?.get(key)
                ?: if (lightFill) LIGHT_DEFAULTS.getValue(key)
                else ContextCompat.getColor(context, RESOURCES.getValue(key))
        }
        return Colors(values)
    }

    private fun isSystemDark(context: Context): Boolean =
        (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    /**
     * Reads the saved form. `v` and a known `mode` are required; a colour that
     * does not parse is dropped, and an unknown key is ignored, so a later
     * version's fields do not break this reader.
     */
    private fun parse(json: JSONObject): Theme? {
        if (!json.has("v")) return null
        val mode = json.optString("mode", "system").lowercase()
        if (mode !in setOf("system", "light", "dark")) return null
        return Theme(mode, colors(json.optJSONObject("light")), colors(json.optJSONObject("dark")))
    }

    private fun colors(set: JSONObject?): Map<String, Int>? {
        set ?: return null
        val out = mutableMapOf<String, Int>()
        for (key in KEYS) {
            val raw = set.optString(key, "").trim()
            if (raw.isEmpty()) continue
            // `#AARRGGBB`, or `#RRGGBB` as opaque.
            runCatching { Color.parseColor(raw) }.getOrNull()?.let { out[key] = it }
        }
        return out
    }

    private fun toJson(map: Map<*, *>): JSONObject? = runCatching {
        JSONObject().apply {
            map["v"]?.let { put("v", (it as Number).toInt()) }
            map["mode"]?.let { put("mode", it.toString()) }
            for (slot in listOf("light", "dark")) {
                (map[slot] as? Map<*, *>)?.let { set ->
                    put(slot, JSONObject().apply {
                        set.forEach { (k, v) -> if (k is String && v is String) put(k, v) }
                    })
                }
            }
        }
    }.getOrNull()

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The eleven colours, resolved. */
    class Colors(private val values: Map<String, Int>) {
        val background get() = values.getValue("background")
        val callerName get() = values.getValue("callerName")
        val subtitle get() = values.getValue("subtitle")
        val avatarBackground get() = values.getValue("avatarBackground")
        val avatarText get() = values.getValue("avatarText")
        val acceptButton get() = values.getValue("acceptButton")
        val acceptIcon get() = values.getValue("acceptIcon")
        val acceptLabel get() = values.getValue("acceptLabel")
        val declineButton get() = values.getValue("declineButton")
        val declineIcon get() = values.getValue("declineIcon")
        val declineLabel get() = values.getValue("declineLabel")
    }
}
