package com.cometchat.voip

import android.content.Context
import android.content.SharedPreferences
import org.mockito.ArgumentMatchers.anyInt
import org.mockito.ArgumentMatchers.anyString
import org.mockito.Mockito

/**
 * Just enough Android for the store: a [Context] whose preferences are
 * in-memory maps, one per name, so a test can read what a process would
 * have persisted and start a "relaunch" from the same maps.
 */
internal class FakeAndroid {

    private val prefs = HashMap<String, FakePrefs>()

    val context: Context = Mockito.mock(Context::class.java).also { context ->
        Mockito.`when`(context.applicationContext).thenReturn(context)
        Mockito.`when`(context.getSharedPreferences(anyString(), anyInt())).thenAnswer { invocation ->
            prefs.getOrPut(invocation.getArgument(0)) { FakePrefs() }
        }
    }

    private class FakePrefs : SharedPreferences {
        private val values = HashMap<String, Any?>()

        override fun getAll(): MutableMap<String, *> = HashMap(values)
        override fun getString(key: String?, defValue: String?): String? = values[key] as? String ?: defValue
        @Suppress("UNCHECKED_CAST")
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
            values[key] as? MutableSet<String> ?: defValues
        override fun getInt(key: String?, defValue: Int): Int = values[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long): Long = values[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float): Float = values[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean): Boolean = values[key] as? Boolean ?: defValue
        override fun contains(key: String?): Boolean = values.containsKey(key)
        override fun edit(): SharedPreferences.Editor = Editor()
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

        private inner class Editor : SharedPreferences.Editor {
            private val puts = HashMap<String, Any?>()
            private val removes = HashSet<String>()
            private var clearAll = false

            override fun putString(key: String, value: String?) = apply { puts[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { puts[key] = values }
            override fun putInt(key: String, value: Int) = apply { puts[key] = value }
            override fun putLong(key: String, value: Long) = apply { puts[key] = value }
            override fun putFloat(key: String, value: Float) = apply { puts[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { puts[key] = value }
            override fun remove(key: String) = apply { removes.add(key) }
            override fun clear() = apply { clearAll = true }
            override fun commit(): Boolean { apply(); return true }
            override fun apply() {
                if (clearAll) values.clear()
                for (k in removes) values.remove(k)
                for ((k, v) in puts) if (v == null) values.remove(k) else values[k] = v
            }
        }
    }
}
