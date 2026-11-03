package com.motalim.adawat.core

import android.content.Context

object Settings {
    private fun prefs(context: Context) = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** "system", "ar" or "en". */
    fun language(context: Context): String = prefs(context).getString("language", "system") ?: "system"

    fun setLanguage(context: Context, value: String) = prefs(context).edit().putString("language", value).apply()

    fun checkForUpdates(context: Context): Boolean = prefs(context).getBoolean("checkForUpdates", true)

    fun setCheckForUpdates(context: Context, value: Boolean) = prefs(context).edit().putBoolean("checkForUpdates", value).apply()

    /** The release the user chose to skip, such as "1.2.0"; no reminder until a newer one. */
    fun skippedVersion(context: Context): String? = prefs(context).getString("skippedVersion", null)

    fun setSkippedVersion(context: Context, value: String) = prefs(context).edit().putString("skippedVersion", value).apply()

    var sounds: Boolean = true
}
