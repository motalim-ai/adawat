package com.motalim.adawat.core

import android.content.Context
import android.content.Intent
import com.motalim.adawat.Actions
import com.motalim.adawat.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** A newer Adawat on GitHub Releases: its notes, and the APK to install. */
data class Release(val version: String, val notes: String, val download: String, val sha256: String)

/**
 * Asks GitHub Releases for a newer Adawat and downloads its APK, checked against the SHA-256 GitHub lists for it.
 * Android then installs it over this one, which it allows only when the APK is signed with the same key.
 */
object Updates {
    const val REPOSITORY = "motalim-ai/adawat"
    private const val ASSET = "Adawat-Android.apk"

    val current: String get() = BuildConfig.VERSION_NAME

    /** The latest release when it is newer than this app and has an APK with a checksum, otherwise null. */
    suspend fun latest(): Release? = withContext(Dispatchers.IO) {
        val connection = open("https://api.github.com/repos/$REPOSITORY/releases/latest")
        val json = connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
        parse(json, current)
    }

    fun parse(release: JSONObject, current: String): Release? {
        val version = release.getString("tag_name").removePrefix("v")
        if (compare(version, current) <= 0) return null
        val assets = release.getJSONArray("assets")
        for (index in 0 until assets.length()) {
            val file = assets.getJSONObject(index)
            if (file.getString("name") != ASSET) continue
            // No checksum, no install: the file could not be checked first.
            val digest = file.optString("digest").takeIf { it.startsWith("sha256:") } ?: return null
            return Release(version, release.optString("body"), file.getString("browser_download_url"), digest.removePrefix("sha256:"))
        }
        return null
    }

    /** "1.10.0" is newer than "1.9.2": compared part by part as numbers. */
    fun compare(a: String, b: String): Int {
        val left = a.split('.').map { it.toIntOrNull() ?: 0 }
        val right = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (index in 0 until maxOf(left.size, right.size)) {
            val difference = left.getOrElse(index) { 0 } - right.getOrElse(index) { 0 }
            if (difference != 0) return difference
        }
        return 0
    }

    /** Downloads the APK into the cache, or throws and leaves nothing behind when it does not match its SHA-256. */
    suspend fun download(context: Context, release: Release, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val apk = File(context.cacheDir, "updates/$ASSET").apply { parentFile!!.mkdirs() }
        val part = File(apk.path + ".part")
        try {
            val connection = open(release.download)
            val total = connection.contentLengthLong
            val hash = MessageDigest.getInstance("SHA-256")
            connection.inputStream.use { input ->
                part.outputStream().use { output ->
                    val buffer = ByteArray(81920)
                    var done = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        hash.update(buffer, 0, read)
                        done += read
                        if (total > 0) progress(done.toFloat() / total)
                    }
                }
            }
            val sha = hash.digest().joinToString("") { "%02x".format(it) }
            if (!sha.equals(release.sha256, ignoreCase = true) || !part.renameTo(apk.apply { delete() })) throw DamagedDownload()
            apk
        } finally {
            part.delete()
        }
    }

    /** Hands the APK to Android's installer, which asks the user to confirm (and, the first time, to allow Adawat to install apps). */
    fun install(context: Context, apk: File) {
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Actions.uri(context, apk), "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    class DamagedDownload : IOException("The update did not download correctly. Try again later.")

    private fun open(url: String) = (URL(url).openConnection() as HttpURLConnection).apply {
        setRequestProperty("User-Agent", "Adawat/$current")
        connectTimeout = 20_000
        readTimeout = 30_000
        instanceFollowRedirects = true
    }
}
