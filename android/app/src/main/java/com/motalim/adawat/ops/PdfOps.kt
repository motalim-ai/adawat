package com.motalim.adawat.ops

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.motalim.adawat.AdawatApp
import com.motalim.adawat.core.AdawatException
import com.motalim.adawat.core.OperationContext
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.contentstream.PDFStreamEngine
import com.tom_roush.pdfbox.contentstream.operator.DrawObject
import com.tom_roush.pdfbox.contentstream.operator.Operator
import com.tom_roush.pdfbox.contentstream.operator.state.Concatenate
import com.tom_roush.pdfbox.contentstream.operator.state.Restore
import com.tom_roush.pdfbox.contentstream.operator.state.Save
import com.tom_roush.pdfbox.contentstream.operator.state.SetGraphicsStateParameters
import com.tom_roush.pdfbox.contentstream.operator.state.SetMatrix
import com.tom_roush.pdfbox.cos.COSBase
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.multipdf.PDFMergerUtility
import com.tom_roush.pdfbox.multipdf.Splitter
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDDocumentInformation
import com.tom_roush.pdfbox.pdmodel.PDResources
import com.tom_roush.pdfbox.pdmodel.graphics.form.PDFormXObject
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import kotlinx.coroutines.ensureActive
import java.io.File
import kotlin.coroutines.coroutineContext
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Everything Adawat does with PDFs on Android: text, pages as pictures, compression, merging, splitting and clean copies. */
object PdfOps {
    private val ready by lazy { PDFBoxResourceLoader.init(AdawatApp.instance); true }

    private fun open(file: File): PDDocument {
        check(ready)
        return try {
            PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
        } catch (e: Exception) {
            throw AdawatException("${file.name} cannot be read or is password-protected")
        }
    }

    fun pageCount(file: File): Int = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { PdfRenderer(it).use { r -> r.pageCount } }

    /** Each page as a picture at [dpi], white behind transparent areas, never larger than [maxSide] pixels. */
    inline fun <T> renderPages(file: File, dpi: Int, maxSide: Int = 5000, each: (index: Int, count: Int, bitmap: Bitmap) -> T): List<T> {
        val results = mutableListOf<T>()
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            val renderer = try { PdfRenderer(descriptor) } catch (e: Exception) { throw AdawatException("${file.name} cannot be read or is password-protected") }
            renderer.use {
                for (index in 0 until renderer.pageCount) {
                    renderer.openPage(index).use { page ->
                        var scale = dpi / 72f
                        scale = min(scale, maxSide.toFloat() / max(page.width, page.height))
                        val bitmap = Bitmap.createBitmap(max(1, (page.width * scale).roundToInt()), max(1, (page.height * scale).roundToInt()), Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                        results += each(index, renderer.pageCount, bitmap)
                        bitmap.recycle()
                    }
                }
            }
        }
        return results
    }

    suspend fun pagesToPictures(files: List<File>, format: ImageFormat, context: OperationContext): List<File> {
        val outputs = mutableListOf<File>()
        for (file in files) {
            val count = pageCount(file)
            val folder = if (count > 1) context.named("${file.nameWithoutExtension} pages").apply { mkdirs() } else null
            renderPages(file, 300) { index, total, bitmap ->
                context.report("Rendering page ${index + 1} of $total")
                context.progress(index.toDouble() / total)
                val output = if (folder != null) File(folder, "Page ${index + 1}.${format.ext}") else context.pathFor(file, format.ext)
                ImageOps.write(bitmap, format, output)
                if (folder == null) outputs += output
            }
            coroutineContext.ensureActive()
            if (folder != null) outputs += folder
        }
        return outputs
    }

    // Text

    /** One line of text, in logical order, with how big it is, for headings in Markdown. */
    data class Line(val text: String, val size: Float, val bold: Boolean, val top: Float = 0f, val bottom: Float = 0f, val words: List<Word> = emptyList())

    /** A word of a line in reading order, with where it sits across the page. */
    data class Word(val text: String, val left: Float, val right: Float)

    /** Collects every glyph with its position; the lines are built from them below. */
    private class Glyphs : PDFTextStripper() {
        val all = mutableListOf<TextPosition>()

        override fun processTextPosition(text: TextPosition) {
            if (text.unicode.isNotBlank()) all += text
        }
    }

    private fun isArabic(c: Char) = c in '\u0600'..'\u06FF' || c in '\u0750'..'\u077F' || c in '\uFB50'..'\uFDFF' || c in '\uFE70'..'\uFEFF'

    /**
     * Lines of a page in reading order, built from glyph positions the way the desktop apps do. PDFs store Arabic as drawn,
     * right to left, so words are put back into logical order here; letting PDFBox reorder whole lines reverses ligatures.
     */
    private fun pageLines(document: PDDocument, page: Int): List<Line>? {
        val glyphs = Glyphs().apply { startPage = page + 1; endPage = page + 1 }
        glyphs.getText(document)
        if (glyphs.all.sumOf { g -> g.unicode.count { it.isLetterOrDigit() } } < 20) return null
        // Lines: glyphs whose baselines sit within half a glyph's height, top to bottom.
        val rows = mutableListOf<MutableList<TextPosition>>()
        for (glyph in glyphs.all.sortedBy { it.yDirAdj }) {
            val height = max(1f, glyph.heightDir)
            val row = rows.lastOrNull { kotlin.math.abs(it[0].yDirAdj - glyph.yDirAdj) < height * 0.5f }
            if (row != null) row += glyph else rows += mutableListOf(glyph)
        }
        return rows.map { row ->
            val ordered = row.sortedBy { it.xDirAdj }
            // Words: a gap wider than a quarter of the usual letter width.
            val average = ordered.map { it.widthDirAdj / max(1, it.unicode.length) }.average().toFloat()
            val words = mutableListOf(mutableListOf(ordered[0]))
            for (i in 1 until ordered.size) {
                val gap = ordered[i].xDirAdj - (ordered[i - 1].xDirAdj + ordered[i - 1].widthDirAdj)
                if (gap > average * 0.25f) words += mutableListOf(ordered[i]) else words.last() += ordered[i]
            }
            val letters = row.sumOf { g -> g.unicode.count { it.isLetter() } }
            val arabic = row.sumOf { g -> g.unicode.count(::isArabic) }
            val rtl = arabic > letters / 2
            val inOrder = if (rtl) words.reversed() else words
            val placed = mutableListOf<Word>()
            val text = inOrder.joinToString(" ") { word ->
                val isArabicWord = word.any { g -> g.unicode.any(::isArabic) }
                val text = (if (isArabicWord) word.reversed() else word).joinToString("") { it.unicode }
                // In a right-to-left line, punctuation after a number or a Latin word is drawn to its left.
                val logical = if (rtl && !isArabicWord) {
                    val leading = text.takeWhile { it in ".,:;!?،؛" }
                    text.drop(leading.length) + leading.reversed()
                } else text
                placed += Word(java.text.Normalizer.normalize(logical, java.text.Normalizer.Form.NFKC), word.first().xDirAdj, word.last().xDirAdj + word.last().widthDirAdj)
                logical
            }.let { java.text.Normalizer.normalize(it, java.text.Normalizer.Form.NFKC) }
            val size = row.map { it.fontSizeInPt }.average().toFloat()
            val bold = row.count { it.font?.name?.contains("Bold", true) == true } > row.size / 2
            Line(text, size, bold, row.minOf { it.yDirAdj - it.heightDir }, row.maxOf { it.yDirAdj }, placed)
        }.filter { it.text.isNotBlank() }
    }

    /** The text of every page: the PDF's own text where it has some, recognised from the page picture where it does not. */
    suspend fun text(file: File, context: OperationContext): String {
        val pages = mutableListOf<String>()
        open(file).use { document ->
            val count = document.numberOfPages
            for (index in 0 until count) {
                coroutineContext.ensureActive()
                context.progress(index.toDouble() / count)
                val lines = pageLines(document, index)
                pages += lines?.joinToString("\n") { it.text.trim() } ?: run {
                    context.report("Recognizing page ${index + 1} of $count")
                    recognizePage(file, index)
                }
            }
        }
        return pages.map { it.trim() }.filter { it.isNotEmpty() }.joinToString("\n\n")
    }

    private fun recognizePage(file: File, index: Int): String =
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
            PdfRenderer(descriptor).use { renderer ->
                renderer.openPage(index).use { page ->
                    val scale = 200f / 72f
                    val bitmap = Bitmap.createBitmap((page.width * scale).roundToInt(), (page.height * scale).roundToInt(), Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
                    Recognition.text(bitmap).replace(Regex("[\\u200E\\u200F]"), "").also { bitmap.recycle() }
                }
            }
        }

    suspend fun toText(files: List<File>, context: OperationContext): List<File> = files.map { file ->
        context.pathFor(file, "txt").apply { writeText(text(file, context)) }
    }

    /** Larger lines become headings and the rest paragraphs, so the Markdown keeps the document's shape. */
    suspend fun toMarkdown(files: List<File>, context: OperationContext): List<File> = files.map { file ->
        val blocks = mutableListOf<String>()
        open(file).use { document ->
            val count = document.numberOfPages
            for (index in 0 until count) {
                coroutineContext.ensureActive()
                context.report("Converting page ${index + 1} of $count")
                context.progress(index.toDouble() / count)
                val lines = pageLines(document, index)
                if (lines == null) {
                    blocks += recognizePage(file, index).trim()
                    continue
                }
                val body = lines.map { it.size }.sorted().let { it[it.size / 2] }
                val paragraph = StringBuilder()
                fun flush() { if (paragraph.isNotBlank()) blocks += paragraph.toString().trim(); paragraph.clear() }
                for (line in lines) {
                    val text = line.text.trim()
                    when {
                        line.size >= body * 1.6f -> { flush(); blocks += "# $text" }
                        line.size >= body * 1.25f || (line.bold && text.length < 80 && line.size >= body) -> { flush(); blocks += "## $text" }
                        else -> paragraph.append(text).append(if (text.endsWith('.') || text.endsWith(':') || text.endsWith('؟') || text.endsWith('?')) "\n" else " ")
                    }
                }
                flush()
            }
        }
        context.pathFor(file, "md").apply { writeText(blocks.filter { it.isNotEmpty() }.joinToString("\n\n") + "\n") }
    }

    /**
     * A PDF as a document, as on the desktop: paragraphs from the text layout, headings from larger type, pictures, and a
     * page break between pages. Scanned pages are recognised.
     */
    suspend fun readDocument(file: File, context: OperationContext? = null): com.motalim.adawat.docs.Doc {
        val doc = com.motalim.adawat.docs.Doc(file.nameWithoutExtension)
        open(file).use { document ->
            val pages = (0 until document.numberOfPages).map { pageLines(document, it) }
            val sizes = pages.filterNotNull().flatten().map { it.size }.sorted()
            val body = if (sizes.isEmpty()) 10f else sizes[sizes.size / 2]
            pages.forEachIndexed { index, lines ->
                coroutineContext.ensureActive()
                context?.progress(index.toDouble() / pages.size)
                if (index > 0) doc.blocks += com.motalim.adawat.docs.PageBreak
                if (lines == null) {
                    recognizePage(file, index).split("\n\n").map { it.trim() }.filter { it.isNotEmpty() }
                        .forEach { doc.blocks += com.motalim.adawat.docs.Paragraph(listOf(com.motalim.adawat.docs.Span(it))) }
                    return@forEachIndexed
                }
                val paragraph = mutableListOf<Line>()
                fun flush() {
                    if (paragraph.isEmpty()) return
                    val text = paragraph.joinToString(" ") { it.text.trim() }
                    val size = paragraph.map { it.size }.average().toFloat()
                    val span = listOf(com.motalim.adawat.docs.Span(text))
                    doc.blocks += when {
                        size > body * 1.6f && text.length < 160 -> com.motalim.adawat.docs.Heading(1, span)
                        size > body * 1.25f && text.length < 160 -> com.motalim.adawat.docs.Heading(2, span)
                        paragraph.all { it.bold } && text.length < 100 && paragraph.size == 1 -> com.motalim.adawat.docs.Heading(3, span)
                        text.startsWith("•") || text.startsWith("- ") -> com.motalim.adawat.docs.ListItem(listOf(com.motalim.adawat.docs.Span(text.trimStart('•', '-', ' '))), false)
                        else -> com.motalim.adawat.docs.Paragraph(span)
                    }
                    paragraph.clear()
                }
                for (line in lines) {
                    paragraph.lastOrNull()?.let { previous ->
                        val gap = line.top - previous.bottom
                        val height = max(1f, previous.bottom - previous.top)
                        if (gap > height * 0.9f || kotlin.math.abs(line.size - previous.size) > 1.5f || previous.bold != line.bold || line.text.trimStart().startsWith("•")) flush()
                    }
                    paragraph += line
                }
                flush()
                pictures(document, index).forEach { doc.blocks += it }
            }
        }
        return doc
    }

    /** Tables on each page become a sheet: text lines are rows, and wide gaps between words split the cells. */
    suspend fun toExcel(files: List<File>, context: OperationContext): List<File> = files.map { file ->
        val sheets = mutableListOf<com.motalim.adawat.docs.Sheet>()
        open(file).use { document ->
            for (index in 0 until document.numberOfPages) {
                coroutineContext.ensureActive()
                context.report("Page ${index + 1} of ${document.numberOfPages}")
                val lines = pageLines(document, index).orEmpty()
                val rtl = lines.sumOf { l -> l.text.count(::isArabic) } > lines.sumOf { it.text.length } / 3
                val rows = lines.map { line ->
                    val words = line.words
                    if (words.isEmpty()) return@map emptyList<Any?>()
                    val averageChar = words.map { (it.right - it.left) / max(1, it.text.length) }.average().toFloat()
                    val cells = mutableListOf(mutableListOf(words[0]))
                    for (i in 1 until words.size) {
                        val gap = if (rtl) words[i - 1].left - words[i].right else words[i].left - words[i - 1].right
                        if (gap > averageChar * 2.2f) cells += mutableListOf(words[i]) else cells.last() += words[i]
                    }
                    cells.map { cell ->
                        val value = cell.joinToString(" ") { it.text }
                        value.replace(",", "").toDoubleOrNull()?.takeIf { !value.startsWith("0") || value == "0" } ?: value
                    }
                }
                sheets += com.motalim.adawat.docs.Sheet("Page ${index + 1}", rows)
            }
        }
        if (sheets.isEmpty()) sheets += com.motalim.adawat.docs.Sheet("Page 1", emptyList())
        context.pathFor(file, "xlsx").also { com.motalim.adawat.docs.SheetOps.write(sheets, "xlsx", it, file.nameWithoutExtension) }
    }

    /** Each page as a picture on its own slide. */
    suspend fun toPowerPoint(files: List<File>, context: OperationContext): List<File> = files.map { file ->
        val slides = renderPages(file, 200, maxSide = 3000) { index, count, bitmap ->
            context.report("Building slide ${index + 1} of $count")
            context.progress(index.toDouble() / count)
            val png = java.io.ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            Triple(png, bitmap.width * 914400L / 200, bitmap.height * 914400L / 200)
        }
        context.pathFor(file, "pptx").also { com.motalim.adawat.docs.Pptx.write(slides, it) }
    }

    /** The larger pictures on a page, as PNG or their own JPEG bytes. */
    private fun pictures(document: PDDocument, index: Int): List<com.motalim.adawat.docs.Picture> {
        val resources = document.getPage(index).resources ?: return emptyList()
        return resources.xObjectNames.mapNotNull { name ->
            val image = runCatching { resources.getXObject(name) }.getOrNull() as? PDImageXObject ?: return@mapNotNull null
            if (image.width < 40 || image.height < 40) return@mapNotNull null
            if (image.suffix == "jpg") runCatching { image.createInputStream(listOf(COSName.DCT_DECODE.name)).use { it.readBytes() } }.getOrNull()
                ?.let { return@mapNotNull com.motalim.adawat.docs.Picture(it, "jpg", image.width, image.height) }
            val bitmap = runCatching { image.image }.getOrNull() ?: return@mapNotNull null
            val bytes = java.io.ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            com.motalim.adawat.docs.Picture(bytes, "png", bitmap.width, bitmap.height)
        }
    }

    // Editing

    /** The files in the order the order screen chose, if it did. */
    fun ordered(files: List<File>, context: OperationContext): List<File> =
        context.options["order"]?.split(',')?.mapNotNull { it.toIntOrNull()?.let(files::getOrNull) }?.takeIf { it.size == files.size } ?: files

    suspend fun merge(files: List<File>, context: OperationContext): List<File> {
        check(ready)
        @Suppress("NAME_SHADOWING") val files = ordered(files, context)
        val output = context.named("${files[0].nameWithoutExtension} merged.pdf")
        var pages = 0
        val merger = PDFMergerUtility().apply { destinationFileName = output.path }
        files.forEachIndexed { index, file ->
            coroutineContext.ensureActive()
            context.progress(index.toDouble() / files.size)
            open(file).use { pages += it.numberOfPages }
            merger.addSource(file)
        }
        try {
            merger.mergeDocuments(MemoryUsageSetting.setupTempFileOnly())
        } catch (e: Exception) {
            throw AdawatException("These PDFs could not be merged.")
        }
        context.finish("Merged ${files.size} PDFs · $pages pages")
        return listOf(output)
    }

    suspend fun split(files: List<File>, context: OperationContext): List<File> = files.map { file ->
        open(file).use { document ->
            if (document.numberOfPages < 2) throw AdawatException("${file.name} has no pages")
            val folder = context.named("${file.nameWithoutExtension} pages").apply { mkdirs() }
            Splitter().split(document).forEachIndexed { index, single ->
                coroutineContext.ensureActive()
                context.progress(index.toDouble() / document.numberOfPages)
                single.use { it.save(File(folder, "Page ${index + 1}.pdf")) }
            }
            folder
        }
    }

    /**
     * The organize screen's pages: "source:rotation" in the new order, pages repeated or left out as chosen, and with
     * [equal widths][context] every page scaled to the widest one.
     */
    suspend fun organize(files: List<File>, context: OperationContext): List<File> {
        val file = files[0]
        val slots = context.text("pages", "").split(',').filter { it.contains(':') }.map { it.split(':').let { (a, b) -> a.toInt() to b.toInt() } }
        if (slots.isEmpty()) throw AdawatException("No pages left")
        val equal = context.bool("equalWidths", false)
        val output = context.pathFor(file, "pdf", "organized")
        open(file).use { source ->
            PDDocument().use { result ->
                val widest = if (equal) slots.maxOf { (i, r) -> source.getPage(i).let { p -> if ((p.rotation + r) % 180 == 0) p.mediaBox.width else p.mediaBox.height } } else 0f
                slots.forEachIndexed { n, (index, turn) ->
                    coroutineContext.ensureActive()
                    context.progress(n.toDouble() / slots.size)
                    val original = source.getPage(index)
                    // A shallow copy, so a page used twice is two pages that share their content.
                    val page = com.tom_roush.pdfbox.pdmodel.PDPage(com.tom_roush.pdfbox.cos.COSDictionary(original.cosObject))
                    // Size, resources and turn can be inherited from the document's page tree; the copy needs its own.
                    page.mediaBox = original.mediaBox
                    page.cropBox = original.cropBox
                    page.resources = original.resources
                    page.cosObject.removeItem(COSName.PARENT)
                    page.rotation = ((original.rotation + turn) % 360 + 360) % 360
                    result.addPage(page)
                    if (equal) {
                        val sideways = page.rotation % 180 != 0
                        val width = if (sideways) page.mediaBox.height else page.mediaBox.width
                        val scale = widest / width
                        if (scale > 1.001f) {
                            val box = page.mediaBox
                            com.tom_roush.pdfbox.pdmodel.PDPageContentStream(result, page, com.tom_roush.pdfbox.pdmodel.PDPageContentStream.AppendMode.PREPEND, true).use {
                                it.saveGraphicsState()
                                it.transform(com.tom_roush.pdfbox.util.Matrix.getScaleInstance(scale, scale))
                            }
                            com.tom_roush.pdfbox.pdmodel.PDPageContentStream(result, page, com.tom_roush.pdfbox.pdmodel.PDPageContentStream.AppendMode.APPEND, true).use { it.restoreGraphicsState() }
                            page.mediaBox = com.tom_roush.pdfbox.pdmodel.common.PDRectangle(box.lowerLeftX * scale, box.lowerLeftY * scale, box.width * scale, box.height * scale)
                            page.cropBox = page.mediaBox
                        }
                    }
                }
                result.save(output)
            }
        }
        return listOf(output)
    }

    suspend fun stripMetadata(files: List<File>, context: OperationContext): List<File> {
        val outputs = files.map { file ->
            coroutineContext.ensureActive()
            open(file).use { document ->
                document.documentInformation = PDDocumentInformation()
                document.documentCatalog.cosObject.removeItem(COSName.METADATA)
                for (page in document.pages) page.cosObject.removeItem(COSName.METADATA)
                context.pathFor(file, "pdf", "clean").also { document.save(it) }
            }
        }
        context.finish(if (files.size == 1) "Metadata removed from 1 PDF" else "Metadata removed from ${files.size} PDFs")
        return outputs
    }

    /**
     * Re-encodes the pictures inside each PDF smaller; text and drawings stay as they are. Each picture keeps enough
     * pixels for the size the page shows it at, so a photo shown small loses only pixels nobody sees.
     */
    suspend fun compress(files: List<File>, context: OperationContext, preset: ImageTools.Preset = ImageTools.Preset.valueOf(context.text("preset", "Balanced"))): List<File> {
        // dpi: pixels kept per inch the picture covers on the page; maxPixels: the most any picture keeps on its longest side.
        val (dpi, maxPixels, quality) = when (preset) {
            ImageTools.Preset.Light -> Triple(220, 2400, 0.82f)
            ImageTools.Preset.Balanced -> Triple(150, 1800, 0.68f)
            ImageTools.Preset.Strong -> Triple(110, 1300, 0.55f)
        }
        val outputs = mutableListOf<File>()
        var before = 0L
        var after = 0L
        for (file in files) {
            val output = context.pathFor(file, "pdf", "compressed")
            open(file).use { document ->
                val placements = Placements()
                document.pages.forEach { runCatching { placements.processPage(it) } }
                val done = HashMap<Any, PDImageXObject?>()
                document.pages.forEachIndexed { index, page ->
                    coroutineContext.ensureActive()
                    context.report("Compressing page ${index + 1} of ${document.numberOfPages}")
                    context.progress(index.toDouble() / document.numberOfPages)
                    // Pictures under 800 pixels, such as logos, stay sharp: they cost little and the text in them blurs first.
                    page.resources?.let { recompress(document, it, done, quality) { image -> placements.shown[image]?.let { (it * dpi).coerceIn(800f, maxPixels.toFloat()).roundToInt() } ?: maxPixels } }
                }
                document.save(output)
            }
            if (output.length() >= file.length()) { output.delete(); continue }
            before += file.length()
            after += output.length()
            outputs += output
        }
        if (outputs.isEmpty()) throw AdawatException("These PDFs are already as small as they get")
        val saved = min(99, 100 - (after.toDouble() / before * 100).roundToInt())
        context.finish(if (outputs.size == 1) "Compressed PDF · $saved% smaller" else "Compressed ${outputs.size} PDFs · $saved% smaller")
        return outputs
    }

    /** [done] maps each picture already handled to its smaller copy (or null when it stays), so pages sharing it share the copy. */
    private fun recompress(document: PDDocument, resources: PDResources, done: MutableMap<Any, PDImageXObject?>, quality: Float, limit: (Any) -> Int) {
        for (name in resources.xObjectNames) {
            val item = runCatching { resources.getXObject(name) }.getOrNull() ?: continue
            if (item.cosObject in done) { done[item.cosObject]?.let { resources.put(name, it) }; continue }
            done[item.cosObject] = null
            when (item) {
                is PDFormXObject -> item.resources?.let { recompress(document, it, done, quality, limit) }
                is PDImageXObject -> {
                    if (item.isStencil || item.width < 64 || item.height < 64) continue
                    // Colour-keyed pictures keep their own encoding: a JPEG would blur the key colour.
                    if (item.cosObject.containsKey(COSName.MASK)) continue
                    val bitmap = runCatching { item.image }.getOrNull() ?: continue
                    val scale = min(1f, limit(item.cosObject).toFloat() / max(bitmap.width, bitmap.height))
                    val sized = if (scale < 1f) Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).roundToInt(), (bitmap.height * scale).roundToInt(), true) else bitmap
                    val smaller = runCatching { JPEGFactory.createFromImage(document, Images.flatten(sized), quality) }.getOrNull() ?: continue
                    if (smaller.cosObject.length >= item.cosObject.length * 0.9) continue
                    // The transparency stays as it was; a soft mask may differ in size from its picture.
                    item.cosObject.getItem(COSName.SMASK)?.let { smaller.cosObject.setItem(COSName.SMASK, it) }
                    resources.put(name, smaller)
                    done[item.cosObject] = smaller
                }
            }
        }
    }

    /** Finds the longest side, in inches, each picture is shown at on the pages it processes. */
    private class Placements : PDFStreamEngine() {
        val shown = HashMap<Any, Float>()

        init {
            listOf(Concatenate(), DrawObject(), SetGraphicsStateParameters(), Save(), Restore(), SetMatrix()).forEach(::addOperator)
        }

        override fun processOperator(operator: Operator, operands: List<COSBase>) {
            val image = if (operator.name == "Do") (operands.firstOrNull() as? COSName)?.let { runCatching { resources.getXObject(it) }.getOrNull() } as? PDImageXObject else null
            if (image == null) return super.processOperator(operator, operands)
            // The picture fills the unit square, so the matrix's two axes are its drawn width and height. A stretched
            // picture keeps the pixels its denser side needs, given as inches along its longest side.
            val matrix = graphicsState.currentTransformationMatrix
            val x = hypot(matrix.getValue(0, 0), matrix.getValue(0, 1)) / 72
            val y = hypot(matrix.getValue(1, 0), matrix.getValue(1, 1)) / 72
            val width = max(image.width, 1)
            val height = max(image.height, 1)
            shown.merge(image.cosObject, max(x / width, y / height) * max(width, height), ::max)
        }
    }

}
