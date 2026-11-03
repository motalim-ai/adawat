package com.motalim.adawat.docs

import com.motalim.adawat.core.AdawatException
import com.motalim.adawat.core.OperationContext
import com.motalim.adawat.core.ext
import com.motalim.adawat.ops.PdfOps
import kotlinx.coroutines.ensureActive
import java.io.File
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import kotlin.coroutines.coroutineContext

enum class DocumentTarget(val ext: String, val title: String) {
    Pdf("pdf", "PDF"), Docx("docx", "DOCX"), Epub("epub", "EPUB"), Md("md", "MD"), Txt("txt", "TXT"), Rtf("rtf", "RTF"), Html("html", "HTML"), Odt("odt", "ODT"),
}

/** Conversions between text documents through [Doc], the same set as the desktop apps. */
object DocumentOps {
    suspend fun load(file: File): Doc = when (file.ext) {
        "docx" -> Docx.read(file)
        "md", "markdown" -> MarkdownFormat.read(readText(file), file.nameWithoutExtension)
        "html", "htm" -> HtmlReader.read(readText(file), file.nameWithoutExtension, { src -> localImage(file, src) })
        "epub" -> Epub.read(file)
        "odt" -> Odt.read(file)
        "rtf" -> Rtf.read(file)
        "pdf" -> PdfOps.readDocument(file)
        "doc" -> throw AdawatException("Old Word documents (.doc) cannot be read on this phone. Save them as .docx first.")
        else -> Doc.fromText(readText(file), file.nameWithoutExtension)
    }

    fun write(doc: Doc, target: DocumentTarget, output: File) {
        when (target) {
            DocumentTarget.Pdf -> DocPdf.write(doc, output)
            DocumentTarget.Docx -> Docx.write(doc, output)
            DocumentTarget.Epub -> Epub.write(doc, output)
            DocumentTarget.Md -> output.writeText(DocText.markdown(doc))
            DocumentTarget.Txt -> output.writeText(doc.plainText)
            DocumentTarget.Rtf -> Rtf.write(doc, output)
            DocumentTarget.Html -> output.writeText(DocText.html(doc))
            DocumentTarget.Odt -> Odt.write(doc, output)
        }
    }

    suspend fun convert(files: List<File>, target: DocumentTarget, context: OperationContext): List<File> = files.mapIndexed { index, file ->
        coroutineContext.ensureActive()
        context.report("Converting ${index + 1} of ${files.size}")
        context.progress(index.toDouble() / files.size)
        val output = context.pathFor(file, target.ext)
        if (target == DocumentTarget.Pdf && file.ext == "docx" && printWord(file, output)) return@mapIndexed output
        write(load(file), target, output)
        output
    }

    /** A Word document drawn page by page with its letterhead, header, footer and layout ([DocxPdf]). False when that
     *  fails, and the document then goes through [Doc] and [DocPdf] instead, which keep the text only. */
    private fun printWord(file: File, output: File): Boolean = try {
        DocxPdf.write(file, output)
        output.isFile && output.length() > 0
    } catch (e: Exception) {
        if (e is kotlinx.coroutines.CancellationException) throw e
        android.util.Log.w("Adawat", "Word page layout failed for ${file.name}, using the plain layout", e)
        false
    } catch (e: OutOfMemoryError) {
        false
    }

    /** Text in UTF-8, UTF-16 or, failing those, the Arabic Windows code page that older files use. */
    fun readText(file: File): String {
        val bytes = file.readBytes()
        if (bytes.size >= 2 && ((bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte()) || (bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte())))
            return String(bytes, Charsets.UTF_16).trimStart('﻿')
        return try {
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(bytes)).toString().trimStart('﻿')
        } catch (e: CharacterCodingException) {
            String(bytes, charset("windows-1256"))
        }
    }

    private fun localImage(page: File, src: String): Pair<ByteArray, String>? {
        if (src.startsWith("http", ignoreCase = true)) return null
        val file = File(page.parentFile, src)
        if (!file.isFile) return null
        val ext = file.ext
        return file.readBytes() to (if (ext == "png" || ext == "gif") ext else "jpg")
    }
}
