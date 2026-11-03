package com.motalim.adawat.work

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import java.io.File
import java.util.UUID

/** Shared files arrive as content links. Each is copied once into the app's cache under its own name, so the tools see ordinary files. */
object Inputs {
    fun stage(context: Context, uris: List<Uri>): List<File> {
        val folder = File(context.cacheDir, "in/${UUID.randomUUID()}").apply { mkdirs() }
        val used = mutableSetOf<String>()
        // Without a storage permission a file:// link can only reach Adawat's own private files, so none are taken.
        return uris.filter { it.scheme != ContentResolver.SCHEME_FILE }.mapNotNull { uri ->
            runCatching {
                var name = sanitize(displayName(context, uri) ?: uri.lastPathSegment ?: "file")
                if (!name.contains('.')) {
                    val type = context.contentResolver.getType(uri)
                    MimeTypeMap.getSingleton().getExtensionFromMimeType(type)?.let { name += ".$it" }
                }
                name = unique(name, used)
                val target = File(folder, name)
                context.contentResolver.openInputStream(uri)!!.use { input -> target.outputStream().use { input.copyTo(it) } }
                target
            }.onFailure { android.util.Log.w("Adawat", "Could not stage $uri", it) }.getOrNull()
        }
    }

    private fun displayName(context: Context, uri: Uri): String? {
        return context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }

    private fun sanitize(name: String) = name.replace(Regex("""[/\\:\u0000]"""), "_").trim().ifEmpty { "file" }

    private fun unique(name: String, used: MutableSet<String>): String {
        var candidate = name
        var n = 2
        while (!used.add(candidate.lowercase())) {
            candidate = name.substringBeforeLast('.') + " $n" + name.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }
            n++
        }
        return candidate
    }

    /** Clears staged files from earlier runs that are no longer in use. */
    fun cleanUp(context: Context, olderThanMillis: Long = 6 * 60 * 60 * 1000L) {
        val now = System.currentTimeMillis()
        listOf("in", "out", "updates").forEach { root ->
            File(context.cacheDir, root).listFiles()?.filter { now - it.lastModified() > olderThanMillis }?.forEach { it.deleteRecursively() }
        }
    }
}

/** Shared text (a link or a note) becomes a text file, so the text tools can take it. */
fun Inputs.stageText(context: android.content.Context, text: String): File {
    val folder = File(context.cacheDir, "in/${java.util.UUID.randomUUID()}").apply { mkdirs() }
    return File(folder, "Text.txt").apply { writeText(text) }
}
