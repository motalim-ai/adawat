package com.motalim.adawat.docs

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextDirectionHeuristics
import android.text.TextPaint
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.LeadingMarginSpan
import android.text.style.LineHeightSpan
import android.text.style.MetricAffectingSpan
import android.text.style.ReplacementSpan
import android.text.style.StrikethroughSpan
import android.text.style.TabStopSpan
import android.text.style.UnderlineSpan
import java.io.Closeable
import java.io.File
import java.util.zip.ZipFile
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A Word document drawn as PDF pages the way Word lays it out: the page size and margins of each section, the
 * header and footer on every page (letterheads, logos, page borders, page numbers), pictures and shapes placed on
 * the page, fonts, sizes, colours, alignment, indents, line spacing, tabs, lists and tables.
 *
 * [DocPdf] draws the simplified [Doc] instead, which keeps only the text and suits every other format; this keeps
 * the look of the page. Text wrapping around floating pictures is not done: they are drawn where Word places them,
 * over or under the text. Fonts that are not on the phone fall back to Android's own.
 */
object DocxPdf {
    fun write(file: File, output: File) {
        Renderer(ZipFile(file)).use { it.render(output) }
    }
}

private const val EMU_PER_POINT = 12700f
private const val PICTURE_DPI = 150f

/** Twentieths of a point, Word's usual unit. Strict files may also write "12pt", "1in" or "2.5cm". */
private fun twips(value: String?): Float? = measure(value, 20f)

private fun emus(value: String?): Float? = measure(value, EMU_PER_POINT)

private fun measure(value: String?, perPoint: Float): Float? {
    val v = value?.trim() ?: return null
    v.toFloatOrNull()?.let { return it / perPoint }
    val number = v.dropLast(2).toFloatOrNull() ?: return null
    return when (v.takeLast(2)) {
        "pt" -> number
        "in" -> number * 72f
        "cm" -> number * 72f / 2.54f
        "mm" -> number * 72f / 25.4f
        "pc", "pi" -> number * 12f
        "px" -> number * 0.75f
        else -> null
    }
}

private fun isOn(value: String?) = value == null || value !in setOf("0", "false", "off", "none")

private fun color(value: String?): Int? {
    if (value == null || value == "auto" || value.length != 6) return null
    return value.toLongOrNull(16)?.let { (0xFF000000 or it).toInt() }
}

private val highlights = mapOf(
    "yellow" to 0xFFFFFF00, "green" to 0xFF00FF00, "cyan" to 0xFF00FFFF, "magenta" to 0xFFFF00FF, "blue" to 0xFF0000FF,
    "red" to 0xFFFF0000, "darkBlue" to 0xFF000080, "darkCyan" to 0xFF008080, "darkGreen" to 0xFF008000, "darkMagenta" to 0xFF800080,
    "darkRed" to 0xFF800000, "darkYellow" to 0xFF808000, "darkGray" to 0xFF808080, "lightGray" to 0xFFC0C0C0, "black" to 0xFF000000,
    "white" to 0xFFFFFFFF,
)

private fun isComplexScript(text: CharSequence) = text.any { it in '֐'..'ࣿ' || it in 'יִ'..'﷿' || it in 'ﹰ'..'﻿' }

/** Fonts that are not on the phone keep their kind: serif, monospaced or sans serif. */
private fun family(name: String?): Typeface {
    val n = name?.lowercase() ?: return Typeface.SANS_SERIF
    return when {
        listOf("courier", "consolas", "mono", "menlo", "lucida console").any { it in n } -> Typeface.MONOSPACE
        "sans" in n -> Typeface.SANS_SERIF
        listOf("times", "georgia", "cambria", "garamond", "antiqua", "palatino", "serif", "traditional arabic", "naskh", "amiri",
               "lotus", "badr", "mitra", "nazanin", "majalla", "typesetting", "scheherazade", "simplified arabic").any { it in n } -> Typeface.SERIF
        else -> Typeface.SANS_SERIF
    }
}

/** Property elements (w:pPr, w:rPr, w:tblPr...) from the weakest to the strongest: the last one that sets a value wins. */
private class Props(val nodes: List<XNode>) {
    fun node(name: String): XNode? {
        for (i in nodes.indices.reversed()) nodes[i].child(name)?.let { return it }
        return null
    }

    fun attr(name: String, attr: String): String? {
        for (i in nodes.indices.reversed()) nodes[i].child(name)?.attr(attr)?.let { return it }
        return null
    }

    fun flag(name: String): Boolean = node(name)?.let { isOn(it.attr("w:val")) } ?: false

    operator fun plus(node: XNode?) = if (node == null) this else Props(nodes + node)
}

private class Border(val width: Float, val color: Int)

private fun border(node: XNode?): Border? {
    val n = node ?: return null
    val kind = n.attr("w:val") ?: return null
    if (kind == "nil" || kind == "none") return null
    val size = (n.attr("w:sz")?.toFloatOrNull() ?: 4f) / 8f
    return Border(max(0.25f, if (kind == "double") size * 3 else size), color(n.attr("w:color")) ?: 0xFF000000.toInt())
}

private fun stroke(b: Border) = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = b.width; color = b.color }

private fun fill(argb: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = argb }

// Drawing pieces

private fun interface Graphic {
    fun draw(canvas: Canvas, rect: RectF)
}

private class PictureGraphic(val bitmap: Bitmap, val crop: RectF?) : Graphic {
    override fun draw(canvas: Canvas, rect: RectF) {
        val source = crop?.let {
            Rect((bitmap.width * it.left).roundToInt(), (bitmap.height * it.top).roundToInt(),
                 (bitmap.width * (1 - it.right)).roundToInt(), (bitmap.height * (1 - it.bottom)).roundToInt())
        }
        canvas.drawBitmap(bitmap, source, rect, Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
    }
}

private class Shape(val geometry: String, val fillColor: Int?, val line: Border?, val flip: Boolean,
                    val text: ((Float) -> List<PageBlock>)?, val insets: RectF, val renderer: Renderer, val section: () -> Section) : Graphic {
    override fun draw(canvas: Canvas, rect: RectF) {
        fillColor?.let {
            when (geometry) {
                "ellipse" -> canvas.drawOval(rect, fill(it))
                "roundRect" -> canvas.drawRoundRect(rect, min(rect.width(), rect.height()) / 6, min(rect.width(), rect.height()) / 6, fill(it))
                "line", "straightConnector1" -> Unit
                else -> canvas.drawRect(rect, fill(it))
            }
        }
        line?.let {
            when (geometry) {
                "ellipse" -> canvas.drawOval(rect, stroke(it))
                "roundRect" -> canvas.drawRoundRect(rect, min(rect.width(), rect.height()) / 6, min(rect.width(), rect.height()) / 6, stroke(it))
                "line", "straightConnector1" ->
                    if (flip) canvas.drawLine(rect.right, rect.top, rect.left, rect.bottom, stroke(it))
                    else canvas.drawLine(rect.left, rect.top, rect.right, rect.bottom, stroke(it))
                else -> canvas.drawRect(rect, stroke(it))
            }
        }
        val content = text ?: return
        val blocks = content(max(1f, rect.width() - insets.left - insets.right))
        canvas.save()
        canvas.clipRect(rect)
        renderer.drawStack(canvas, blocks, rect.left + insets.left, rect.top + insets.top, section(), behind = true)
        renderer.drawStack(canvas, blocks, rect.left + insets.left, rect.top + insets.top, section(), behind = false)
        canvas.restore()
    }
}

/** A group of shapes and pictures, each placed in the group's own coordinates. */
private class Group(val children: List<Pair<Graphic, RectF>>, val space: RectF) : Graphic {
    override fun draw(canvas: Canvas, rect: RectF) {
        val sx = rect.width() / max(1e-3f, space.width())
        val sy = rect.height() / max(1e-3f, space.height())
        for ((graphic, r) in children) {
            graphic.draw(canvas, RectF(rect.left + (r.left - space.left) * sx, rect.top + (r.top - space.top) * sy,
                                       rect.left + (r.right - space.left) * sx, rect.top + (r.bottom - space.top) * sy))
        }
    }
}

/** A picture or shape placed on the page rather than in the line: positioned from the page, the margins or its paragraph. */
private class Anchor(
    val graphic: Graphic, val width: Float, val height: Float, val behind: Boolean,
    val horizontalFrom: String, val horizontalOffset: Float?, val horizontalAlign: String?,
    val verticalFrom: String, val verticalOffset: Float?, val verticalAlign: String?,
) {
    fun rect(s: Section, paragraphTop: Float): RectF {
        val (x0, x1) = when (horizontalFrom) {
            "page" -> 0f to s.pageWidth
            "leftMargin" -> 0f to s.left
            "rightMargin" -> s.pageWidth - s.right to s.pageWidth
            else -> s.left to s.pageWidth - s.right
        }
        val x = horizontalOffset?.let { x0 + it } ?: when (horizontalAlign) {
            "center" -> (x0 + x1 - width) / 2
            "right", "outside" -> x1 - width
            else -> x0
        }
        val (y0, y1) = when (verticalFrom) {
            "page" -> 0f to s.pageHeight
            "margin" -> s.top to s.pageHeight - s.bottom
            "topMargin" -> 0f to s.top
            "bottomMargin" -> s.pageHeight - s.bottom to s.pageHeight
            "insideMargin", "outsideMargin" -> s.top to s.pageHeight - s.bottom
            else -> paragraphTop to paragraphTop
        }
        val y = verticalOffset?.let { y0 + it } ?: when (verticalAlign) {
            "center" -> (y0 + y1 - height) / 2
            "bottom", "outside" -> y1 - height
            else -> y0
        }
        return RectF(x, y, x + width, y + height)
    }

    fun draw(canvas: Canvas, s: Section, paragraphTop: Float) = graphic.draw(canvas, rect(s, paragraphTop))
}

// Text spans

/** A run's font: Word's sizes are points, and so are the PDF page's units. */
private class RunSpan(val size: Float, val typeface: Typeface, val bold: Boolean, val italic: Boolean, val vertical: String?,
                      val spacing: Float) : MetricAffectingSpan() {
    override fun updateMeasureState(paint: TextPaint) = apply(paint)
    override fun updateDrawState(paint: TextPaint) = apply(paint)

    private fun apply(paint: TextPaint) {
        val style = (if (bold) Typeface.BOLD else 0) or (if (italic) Typeface.ITALIC else 0)
        val face = Typeface.create(typeface, style)
        val missing = style and face.style.inv()
        paint.typeface = face
        paint.isFakeBoldText = missing and Typeface.BOLD != 0
        paint.textSkewX = if (missing and Typeface.ITALIC != 0) -0.25f else 0f
        paint.textSize = if (vertical == null) size else size * 0.65f
        if (spacing != 0f) paint.letterSpacing = spacing / size
        when (vertical) {
            "superscript" -> paint.baselineShift += (size * -0.33f).roundToInt()
            "subscript" -> paint.baselineShift += (size * 0.14f).roundToInt()
        }
    }
}

/** Word's line spacing: a multiple of the font's own line height, at least a height, or exactly one. */
private class LineSpacing(val rule: String, val value: Float) : LineHeightSpan {
    override fun chooseHeight(text: CharSequence, start: Int, end: Int, spanstartv: Int, lineHeight: Int, fm: Paint.FontMetricsInt) {
        val natural = fm.descent - fm.ascent
        val target = when (rule) {
            "exact" -> value
            "atLeast" -> max(value, natural.toFloat())
            else -> natural * value
        }
        val extra = (target - natural).roundToInt()
        fm.descent += extra
        fm.bottom = fm.descent
        fm.top = min(fm.top, fm.ascent)
    }
}

/** A picture or shape that sits in the line like a letter. */
private class GraphicSpan(val graphic: Graphic, val width: Float, val height: Float) : ReplacementSpan() {
    override fun getSize(paint: Paint, text: CharSequence?, start: Int, end: Int, fm: Paint.FontMetricsInt?): Int {
        if (fm != null) {
            fm.ascent = -height.roundToInt()
            fm.descent = 0
            fm.top = fm.ascent
            fm.bottom = 0
        }
        return width.roundToInt()
    }

    override fun draw(canvas: Canvas, text: CharSequence?, start: Int, end: Int, x: Float, top: Int, y: Int, bottom: Int, paint: Paint) {
        graphic.draw(canvas, RectF(x, y - height, x + width, y.toFloat()))
    }
}

// Laid-out blocks

private sealed interface PageBlock

private class ParaBlock(
    val layout: StaticLayout, val x: Float, val width: Float, val before: Float, val after: Float,
    val anchors: List<Anchor>, val breakBefore: Boolean, val style: String?, val contextual: Boolean,
    val shading: Int?, val top: Border?, val bottom: Border?, val start: Border?, val end: Border?, val rtl: Boolean,
) : PageBlock {
    /** Lines [first]..[last] drawn with their top at [y], container starting at [left]. */
    fun draw(canvas: Canvas, left: Float, y: Float, first: Int, last: Int, pageWidth: Float) {
        val lineTop = layout.getLineTop(first).toFloat()
        val height = layout.getLineBottom(last) - lineTop
        val x = left + this.x
        shading?.let { canvas.drawRect(x, y, x + width, y + height, fill(it)) }
        if (first == 0) this.top?.let { canvas.drawLine(x, y, x + width, y, stroke(it)) }
        if (last == layout.lineCount - 1) this.bottom?.let { canvas.drawLine(x, y + height, x + width, y + height, stroke(it)) }
        (if (rtl) end else start)?.let { canvas.drawLine(x, y, x, y + height, stroke(it)) }
        (if (rtl) start else end)?.let { canvas.drawLine(x + width, y, x + width, y + height, stroke(it)) }
        // A little room above and below so diacritics and tall letters at the edges are not cut off.
        val slack = (layout.getLineBottom(first) - layout.getLineTop(first)) * 0.35f
        canvas.save()
        canvas.translate(x, y - lineTop)
        canvas.clipRect(-x, lineTop - (if (first == 0) slack * 2 else slack), pageWidth - x, lineTop + height + (if (last == layout.lineCount - 1) slack * 2 else slack))
        layout.draw(canvas)
        canvas.restore()
    }
}

private class Cell(val blocks: List<PageBlock>, val x: Float, val width: Float, val padding: RectF, val shading: Int?,
                   val left: Border?, val right: Border?, val top: Border?, val bottom: Border?, val vAlign: String?,
                   val merged: Boolean, val content: Float)

private class Row(val cells: List<Cell>, val height: Float)

private class TableBlock(val rows: List<Row>, val x: Float) : PageBlock {
    val height get() = rows.sumOf { it.height.toDouble() }.toFloat()
}

private class PageNumbers(val page: Int, val total: Int)

/** A field being read (PAGE, NUMPAGES...): its instruction, and whether its shown result has started or been replaced. */
private class Field { val instruction = StringBuilder(); var separated = false; var replaced = false }

internal class Section(sectPr: XNode?, val children: List<XNode>, previous: Section?, rels: Map<String, String>) {
    val pageWidth = twips(sectPr?.child("w:pgSz")?.attr("w:w")) ?: 612f
    val pageHeight = twips(sectPr?.child("w:pgSz")?.attr("w:h")) ?: 792f
    private val margins = sectPr?.child("w:pgMar")
    private val gutter = twips(margins?.attr("w:gutter")) ?: 0f
    private val rtlGutter = sectPr?.child("w:rtlGutter")?.let { isOn(it.attr("w:val")) } ?: false
    val top = kotlin.math.abs(twips(margins?.attr("w:top")) ?: 72f)
    val bottom = kotlin.math.abs(twips(margins?.attr("w:bottom")) ?: 72f)
    val left = (twips(margins?.attr("w:left")) ?: 72f) + if (rtlGutter) 0f else gutter
    val right = (twips(margins?.attr("w:right")) ?: 72f) + if (rtlGutter) gutter else 0f
    val headerDistance = twips(margins?.attr("w:header")) ?: 36f
    val footerDistance = twips(margins?.attr("w:footer")) ?: 36f
    val fixedTop = (twips(margins?.attr("w:top")) ?: 0f) < 0
    val fixedBottom = (twips(margins?.attr("w:bottom")) ?: 0f) < 0
    val titlePage = sectPr?.child("w:titlePg")?.let { isOn(it.attr("w:val")) } ?: false
    val start = sectPr?.child("w:type")?.attr("w:val") ?: "nextPage"
    val textWidth get() = pageWidth - left - right

    /** Header and footer parts by type (default, first, even); a section without its own keeps the previous section's. */
    val headers: Map<String, String> = references(sectPr, "w:headerReference", rels, previous?.headers)
    val footers: Map<String, String> = references(sectPr, "w:footerReference", rels, previous?.footers)

    private fun references(sectPr: XNode?, name: String, rels: Map<String, String>, inherited: Map<String, String>?): Map<String, String> {
        val own = sectPr?.elements(name).orEmpty().mapNotNull { r -> rels[r.attr("r:id") ?: ""]?.let { (r.attr("w:type") ?: "default") to it } }.toMap()
        return (inherited.orEmpty()) + own
    }
}

private class Part(val root: XNode, val rels: Map<String, String>)

private class PageOut(val section: Section, val firstOfSection: Boolean) {
    val back = mutableListOf<(Canvas) -> Unit>()
    val text = mutableListOf<(Canvas) -> Unit>()
    val front = mutableListOf<(Canvas) -> Unit>()
    var hasContent = false
}

private class Renderer(val zip: ZipFile) : Closeable {
    private val parts = HashMap<String, Part?>()
    private val bitmaps = HashMap<String, Bitmap?>()
    private val documentPath: String
    private val document: Part
    private val styles: Map<String, XNode>
    private val defaultRun: XNode?
    private val defaultParagraph: XNode?
    private val defaultParagraphStyle: String?
    private val defaultTableStyle: String?
    private val numbering: XNode?
    private val defaultTab: Float
    private val evenAndOdd: Boolean

    init {
        val packageRels = entry("_rels/.rels")?.descendants("Relationship")
        documentPath = packageRels?.firstOrNull { it.attr("Type")?.endsWith("/officeDocument") == true }?.attr("Target")?.removePrefix("/") ?: "word/document.xml"
        document = part(documentPath) ?: throw com.motalim.adawat.core.AdawatException("This file could not be read as a Word document")
        // Relationship types of the main document, by id, to find its styles, numbering and settings.
        val dir = documentPath.substringBeforeLast('/', "")
        val relType = entry((if (dir.isEmpty()) "" else "$dir/") + "_rels/" + documentPath.substringAfterLast('/') + ".rels")
            ?.descendants("Relationship")?.associate { (it.attr("Id") ?: "") to (it.attr("Type") ?: "") }.orEmpty()
        val related = { suffix: String -> document.rels.entries.firstOrNull { relType[it.key]?.endsWith(suffix) == true }?.value }
        val stylesRoot = related("/styles")?.let { part(it)?.root }
        styles = stylesRoot?.descendants("w:style")?.associateBy { it.attr("w:styleId") ?: "" }.orEmpty()
        defaultRun = stylesRoot?.descendants("w:rPrDefault")?.firstOrNull()?.child("w:rPr")
        defaultParagraph = stylesRoot?.descendants("w:pPrDefault")?.firstOrNull()?.child("w:pPr")
        fun defaultStyle(type: String) = styles.values.firstOrNull { it.attr("w:type") == type && it.attr("w:default").let { d -> d == "1" || d == "true" || d == "on" } }?.attr("w:styleId")
        defaultParagraphStyle = defaultStyle("paragraph")
        defaultTableStyle = defaultStyle("table")
        numbering = related("/numbering")?.let { part(it)?.root }
        val settings = related("/settings")?.let { part(it)?.root }
        defaultTab = twips(settings?.descendants("w:defaultTabStop")?.firstOrNull()?.attr("w:val"))?.takeIf { it > 1 } ?: 36f
        evenAndOdd = settings?.descendants("w:evenAndOddHeaders")?.firstOrNull()?.let { isOn(it.attr("w:val")) } ?: false
    }

    override fun close() = zip.close()

    private fun entry(path: String): XNode? = zip.getEntry(path)?.let { e -> zip.getInputStream(e).use { Xml.parse(it) } }

    private fun resolve(dir: String, target: String): String {
        if (target.startsWith("/")) return target.drop(1)
        val parts = (if (dir.isEmpty()) emptyList() else dir.split('/')).toMutableList()
        for (piece in target.split('/')) when (piece) {
            ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.size - 1)
            ".", "" -> Unit
            else -> parts += piece
        }
        return parts.joinToString("/")
    }

    fun part(path: String): Part? = parts.getOrPut(path) {
        val root = entry(path) ?: return@getOrPut null
        val dir = path.substringBeforeLast('/', "")
        val rels = entry((if (dir.isEmpty()) "" else "$dir/") + "_rels/" + path.substringAfterLast('/') + ".rels")
            ?.descendants("Relationship")?.filter { it.attr("TargetMode") != "External" }
            ?.associate { (it.attr("Id") ?: "") to resolve(dir, it.attr("Target") ?: "") }.orEmpty()
        Part(root, rels)
    }

    private fun bitmap(path: String, width: Float, height: Float): Bitmap? = bitmaps.getOrPut(path) {
        val data = zip.getEntry(path)?.let { e -> zip.getInputStream(e).use { it.readBytes() } } ?: return@getOrPut null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@getOrPut null
        // Enough pixels for print, not the full camera resolution.
        val wanted = max(width, height) / 72f * PICTURE_DPI
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= wanted) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return@getOrPut null
        val scale = wanted / max(decoded.width, decoded.height)
        if (scale < 0.67f) Bitmap.createScaledBitmap(decoded, max(1, (decoded.width * scale).roundToInt()), max(1, (decoded.height * scale).roundToInt()), true)
        else decoded
    }

    private fun styleChain(id: String?): List<XNode> {
        val chain = ArrayList<XNode>()
        val seen = HashSet<String>()
        var current = id
        while (current != null && seen.add(current)) {
            val style = styles[current] ?: break
            chain.add(0, style)
            current = style.child("w:basedOn")?.attr("w:val")
        }
        return chain
    }

    fun tableStyle(tblPr: XNode?): List<XNode> = styleChain(tblPr?.child("w:tblStyle")?.attr("w:val") ?: defaultTableStyle)

    // Rendering

    fun render(output: File) {
        val body = document.root.descendants("w:body").firstOrNull() ?: throw com.motalim.adawat.core.AdawatException("This Word document has no body")
        val sections = ArrayList<Section>()
        var pending = ArrayList<XNode>()
        for (child in body.children) {
            if (child.name == "w:sectPr") continue
            pending += child
            val sectPr = if (child.name == "w:p") child.child("w:pPr")?.child("w:sectPr") else null
            if (sectPr != null) {
                sections += Section(sectPr, pending, sections.lastOrNull(), document.rels)
                pending = ArrayList()
            }
        }
        sections += Section(body.child("w:sectPr"), pending, sections.lastOrNull(), document.rels)

        val flow = Flow()
        val builder = Builder(document, null)
        sections.forEachIndexed { index, section ->
            flow.begin(section, index == 0)
            for (child in section.children) {
                for (block in builder.blocksFor(child, section.textWidth, emptyList(), section)) flow.add(block)
            }
        }

        flow.finish()
        val pdf = PdfDocument()
        try {
            flow.pages.forEachIndexed { index, out ->
                val s = out.section
                val page = pdf.startPage(PdfDocument.PageInfo.Builder(s.pageWidth.roundToInt(), s.pageHeight.roundToInt(), index + 1).create())
                val canvas = page.canvas
                val numbers = PageNumbers(index + 1, flow.pages.size)
                val header = headerBlocks(s.headers, out, index + 1, numbers)
                val footer = headerBlocks(s.footers, out, index + 1, numbers)
                val footerTop = s.pageHeight - s.footerDistance - (footer?.let { stackHeight(it) } ?: 0f)
                header?.let { drawStack(canvas, it, s.left, s.headerDistance, s, behind = true) }
                footer?.let { drawStack(canvas, it, s.left, footerTop, s, behind = true) }
                out.back.forEach { it(canvas) }
                header?.let { drawStack(canvas, it, s.left, s.headerDistance, s, behind = false) }
                footer?.let { drawStack(canvas, it, s.left, footerTop, s, behind = false) }
                out.text.forEach { it(canvas) }
                out.front.forEach { it(canvas) }
                pdf.finishPage(page)
            }
            output.outputStream().buffered().use { pdf.writeTo(it) }
        } finally {
            pdf.close()
        }
    }

    private fun headerBlocks(refs: Map<String, String>, page: PageOut, number: Int, numbers: PageNumbers): List<PageBlock>? {
        val type = when {
            page.firstOfSection && page.section.titlePage -> "first"
            evenAndOdd && number % 2 == 0 -> "even"
            else -> "default"
        }
        val path = refs[type] ?: return null
        val part = part(path) ?: return null
        val root = part.root.children.firstOrNull { it.name == "w:hdr" || it.name == "w:ftr" } ?: return null
        return Builder(part, numbers).blocks(root, page.section.textWidth, emptyList(), page.section)
    }

    private fun spacing(previous: ParaBlock?, block: ParaBlock): Float {
        if (previous == null) return block.before
        val same = previous.style == block.style
        val after = if (same && previous.contextual) 0f else previous.after
        val before = if (same && block.contextual) 0f else block.before
        return after + before
    }

    fun stackHeight(blocks: List<PageBlock>): Float {
        var y = 0f
        var previous: ParaBlock? = null
        for (b in blocks) when (b) {
            is ParaBlock -> { y += spacing(previous, b) + b.layout.height; previous = b }
            is TableBlock -> { y += (previous?.after ?: 0f) + b.height; previous = null }
        }
        return y + (previous?.after ?: 0f)
    }

    /** Blocks one under the other, as in a header, a table cell or a text box: either only the pictures behind the
     *  text, or the text and the pictures in front of it. */
    fun drawStack(canvas: Canvas, blocks: List<PageBlock>, x: Float, top: Float, s: Section, behind: Boolean) {
        var y = top
        var previous: ParaBlock? = null
        for (b in blocks) when (b) {
            is ParaBlock -> {
                y += spacing(previous, b)
                for (a in b.anchors) if (a.behind == behind) a.draw(canvas, s, y)
                if (!behind) b.draw(canvas, x, y, 0, b.layout.lineCount - 1, s.pageWidth)
                y += b.layout.height
                previous = b
            }
            is TableBlock -> {
                y += previous?.after ?: 0f
                var rowTop = y
                for (row in b.rows) { drawRow(canvas, row, x + b.x, rowTop, s, behind); rowTop += row.height }
                y += b.height
                previous = null
            }
        }
    }

    fun drawRow(canvas: Canvas, row: Row, x: Float, y: Float, s: Section, behind: Boolean) {
        for (cell in row.cells) {
            val left = x + cell.x
            if (!behind) cell.shading?.let { canvas.drawRect(left, y, left + cell.width, y + row.height, fill(it)) }
            if (!cell.merged) {
                val free = row.height - cell.content - cell.padding.top - cell.padding.bottom
                val offset = when (cell.vAlign) { "center" -> free / 2; "bottom" -> free; else -> 0f }.coerceAtLeast(0f)
                drawStack(canvas, cell.blocks, left + cell.padding.left, y + cell.padding.top + offset, s, behind)
            }
            if (behind) continue
            cell.top?.let { canvas.drawLine(left, y, left + cell.width, y, stroke(it)) }
            cell.bottom?.let { canvas.drawLine(left, y + row.height, left + cell.width, y + row.height, stroke(it)) }
            cell.left?.let { canvas.drawLine(left, y, left, y + row.height, stroke(it)) }
            cell.right?.let { canvas.drawLine(left + cell.width, y, left + cell.width, y + row.height, stroke(it)) }
        }
    }

    /** Body blocks poured onto pages, paragraphs split between lines and tables between rows. */
    private inner class Flow {
        val pages = ArrayList<PageOut>()
        private lateinit var section: Section
        private var page: PageOut? = null
        private var startsSection = true
        private var y = 0f
        private var bottom = 0f
        private var previous: ParaBlock? = null

        fun begin(s: Section, first: Boolean) {
            val sameSize = !first && s.pageWidth == section.pageWidth && s.pageHeight == section.pageHeight
            section = s
            if (first) { startsSection = true; return }
            if (s.start == "continuous" && sameSize) return
            page = null
            startsSection = true
            if ((s.start == "evenPage" && pages.size % 2 == 1) || (s.start == "oddPage" && pages.size % 2 == 0)) {
                pages += PageOut(s, true)
            }
        }

        private fun current(): PageOut {
            page?.let { return it }
            val s = section
            val out = PageOut(s, startsSection)
            startsSection = false
            pages += out
            page = out
            // A header or footer taller than its margin pushes the text away, as in Word.
            val numbers = PageNumbers(pages.size, pages.size)
            val header = if (s.fixedTop) null else headerBlocks(s.headers, out, pages.size, numbers)
            val footer = if (s.fixedBottom) null else headerBlocks(s.footers, out, pages.size, numbers)
            y = max(s.top, header?.let { s.headerDistance + stackHeight(it) } ?: 0f)
            bottom = min(s.pageHeight - s.bottom, footer?.let { s.pageHeight - s.footerDistance - stackHeight(it) } ?: Float.MAX_VALUE)
            previous = null
            return out
        }

        /** An empty document still has its first page, with its header and footer. */
        fun finish() {
            if (pages.isEmpty()) current()
        }

        private fun newPage() {
            page = null
        }

        fun add(block: PageBlock) = when (block) {
            is ParaBlock -> paragraph(block)
            is TableBlock -> table(block)
        }

        private fun paragraph(b: ParaBlock) {
            if (b.breakBefore && page != null) newPage()
            var out = current()
            y += spacing(previous, b)
            val layout = b.layout
            val firstLine = (layout.getLineBottom(0) - layout.getLineTop(0)).toFloat()
            if (y + firstLine > bottom && out.hasContent) { newPage(); out = current() }
            val s = section
            val paragraphTop = y
            for (a in b.anchors) (if (a.behind) out.back else out.front) += { c -> a.draw(c, s, paragraphTop) }
            var line = 0
            while (line < layout.lineCount) {
                out = current()
                val lineTop = layout.getLineTop(line)
                if (y + layout.getLineBottom(line) - lineTop > bottom && out.hasContent) { newPage(); continue }
                var last = line
                while (last + 1 < layout.lineCount && y + layout.getLineBottom(last + 1) - lineTop <= bottom) last++
                val top = y
                val first = line
                val end = last
                val left = s.left
                out.text += { c -> b.draw(c, left, top, first, end, s.pageWidth) }
                out.hasContent = true
                y += layout.getLineBottom(last) - lineTop
                line = last + 1
            }
            previous = b
        }

        private fun table(t: TableBlock) {
            y += previous?.after ?: 0f
            previous = null
            for (row in t.rows) {
                var out = current()
                if (y + row.height > bottom && out.hasContent) { newPage(); out = current() }
                val top = y
                val x = section.left + t.x
                val s = section
                out.back += { c -> drawRow(c, row, x, top, s, behind = true) }
                out.text += { c -> drawRow(c, row, x, top, s, behind = false) }
                out.hasContent = true
                y += row.height
            }
        }
    }

    /** Turns the paragraphs and tables of one part (the document, a header or a footer) into laid-out blocks. */
    inner class Builder(private val part: Part, private val numbers: PageNumbers?) {
        private val counters = HashMap<String, IntArray>()

        fun blocks(container: XNode, width: Float, tableStyle: List<XNode>, s: Section): List<PageBlock> =
            container.children.flatMap { blocksFor(it, width, tableStyle, s) }

        fun blocksFor(node: XNode, width: Float, tableStyle: List<XNode>, s: Section): List<PageBlock> = when (node.name) {
            "w:p" -> paragraph(node, width, tableStyle, s)
            "w:tbl" -> listOfNotNull(table(node, width, s))
            "w:sdt" -> node.child("w:sdtContent")?.let { blocks(it, width, tableStyle, s) }.orEmpty()
            "w:customXml", "w:ins", "w:moveTo", "w:sdtContent" -> blocks(node, width, tableStyle, s)
            "mc:AlternateContent" -> (node.child("mc:Choice") ?: node.child("mc:Fallback"))?.let { blocks(it, width, tableStyle, s) }.orEmpty()
            else -> emptyList()
        }

        // Paragraphs

        private inner class Segment {
            val text = SpannableStringBuilder()
            val anchors = ArrayList<Anchor>()
        }

        private fun paragraph(p: XNode, width: Float, tableStyle: List<XNode>, s: Section): List<PageBlock> {
            val pPr = p.child("w:pPr")
            val styleId = pPr?.child("w:pStyle")?.attr("w:val") ?: defaultParagraphStyle
            val chain = styleChain(styleId)
            val base = listOfNotNull(defaultParagraph) + tableStyle.mapNotNull { it.child("w:pPr") } + chain.mapNotNull { it.child("w:pPr") }
            val numPr = Props(base + listOfNotNull(pPr)).node("w:numPr")
            val level = numberingLevel(numPr, Props(base + listOfNotNull(pPr)))
            val props = Props(base + listOfNotNull(level?.child("w:pPr"), pPr))
            val runBase = Props(listOfNotNull(defaultRun) + tableStyle.mapNotNull { it.child("w:rPr") } + chain.mapNotNull { it.child("w:rPr") })
            val mark = runBase + pPr?.child("w:rPr")
            val rtl = props.flag("w:bidi")

            val segments = arrayListOf(Segment())
            val fields = ArrayList<Field>()

            fun append(text: String, run: Props) {
                if (text.isEmpty()) return
                val shown = if (run.flag("w:caps")) text.uppercase() else text
                val segment = segments.last()
                val start = segment.text.length
                segment.text.append(shown)
                style(segment.text, start, segment.text.length, run, isComplexScript(shown) || run.flag("w:rtl") || run.flag("w:cs"))
            }

            fun inline(graphic: Graphic, w: Float, h: Float) {
                val segment = segments.last()
                val start = segment.text.length
                segment.text.append('￼')
                segment.text.setSpan(GraphicSpan(graphic, w, h), start, start + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            }

            fun hidden() = fields.any { !it.separated || it.replaced }

            fun content(node: XNode, run: Props) {
                for (c in node.children) {
                    when (c.name) {
                        "w:fldChar" -> when (c.attr("w:fldCharType")) {
                            "begin" -> fields += Field()
                            "separate" -> fields.lastOrNull()?.let { f ->
                                f.separated = true
                                fieldValue(f.instruction.toString())?.let { value -> if (!hidden()) append(value, run); f.replaced = true }
                            }
                            "end" -> if (fields.isNotEmpty()) fields.removeAt(fields.size - 1)
                        }
                        "w:instrText" -> fields.lastOrNull()?.instruction?.append(c.innerText)
                        else -> {
                            if (hidden()) continue
                            when (c.name) {
                                "w:t" -> append(c.innerText, run)
                                "w:tab", "w:ptab" -> append("\t", run)
                                "w:br" -> when (c.attr("w:type")) {
                                    "page", "column" -> segments += Segment()
                                    else -> append("\n", run)
                                }
                                "w:cr" -> append("\n", run)
                                "w:noBreakHyphen" -> append("‑", run)
                                "w:softHyphen" -> append("­", run)
                                "w:sym" -> c.attr("w:char")?.toIntOrNull(16)?.let { code ->
                                    append(if (code in 0xF000..0xF0FF) symbol(code) else String(Character.toChars(code)), run)
                                }
                                "w:drawing" -> for (d in c.children) {
                                    val (graphic, w, h) = graphic(d, s) ?: continue
                                    if (d.name == "wp:anchor") segments.last().anchors += anchor(d, graphic, w, h) else inline(graphic, w, h)
                                }
                                "w:pict", "w:object" -> vml(c, s)?.let { (graphic, w, h, anchor) ->
                                    if (anchor != null) segments.last().anchors += anchor else inline(graphic, w, h)
                                }
                                "mc:AlternateContent" -> (c.child("mc:Choice") ?: c.child("mc:Fallback"))?.let { content(it, run) }
                            }
                        }
                    }
                }
            }

            fun walk(node: XNode) {
                for (c in node.children) when (c.name) {
                    "w:r" -> {
                        val rPr = c.child("w:rPr")
                        val run = Props(runBase.nodes + styleChain(rPr?.child("w:rStyle")?.attr("w:val")).mapNotNull { it.child("w:rPr") } + listOfNotNull(rPr))
                        if (run.flag("w:vanish") || run.flag("w:specVanish")) continue
                        content(c, run)
                    }
                    "w:fldSimple" -> {
                        val value = fieldValue(c.attr("w:instr") ?: "")
                        if (value != null) {
                            val rPr = c.descendants("w:rPr").firstOrNull()
                            append(value, Props(runBase.nodes + listOfNotNull(rPr)))
                        } else walk(c)
                    }
                    "w:hyperlink", "w:ins", "w:smartTag", "w:customXml", "w:dir", "w:bdo", "w:moveTo", "w:sdtContent" -> walk(c)
                    "w:sdt" -> c.child("w:sdtContent")?.let { walk(it) }
                    "mc:AlternateContent" -> (c.child("mc:Choice") ?: c.child("mc:Fallback"))?.let { walk(it) }
                }
            }
            walk(p)

            // Indents: "left" and "right" are the paragraph's start and end, also in right-to-left paragraphs.
            val startIndent = twips(props.attr("w:ind", "w:start") ?: props.attr("w:ind", "w:left")) ?: 0f
            val endIndent = twips(props.attr("w:ind", "w:end") ?: props.attr("w:ind", "w:right")) ?: 0f
            val hanging = twips(props.attr("w:ind", "w:hanging"))
            val firstIndent = if (hanging != null) -hanging else twips(props.attr("w:ind", "w:firstLine")) ?: 0f
            val firstMargin = startIndent + firstIndent
            val shift = -min(0f, min(startIndent, firstMargin))

            level?.let { lvl -> label(lvl, numPr)?.let { prefix ->
                val text = segments.first().text
                text.insert(0, prefix)
                style(text, 0, prefix.length, mark + lvl.child("w:rPr"), isComplexScript(prefix) || rtl)
            } }

            val before = if (props.attr("w:spacing", "w:beforeAutospacing")?.let(::isOn) == true) 14f
                         else twips(props.attr("w:spacing", "w:before")) ?: 0f
            val after = if (props.attr("w:spacing", "w:afterAutospacing")?.let(::isOn) == true) 14f
                        else twips(props.attr("w:spacing", "w:after")) ?: 0f
            val lineRule = props.attr("w:spacing", "w:lineRule") ?: "auto"
            val lineValue = props.attr("w:spacing", "w:line")?.toFloatOrNull()
            val lineSpacing = when {
                lineValue == null -> null
                lineRule == "auto" -> LineSpacing("auto", lineValue / 240f)
                else -> LineSpacing(lineRule, lineValue / 20f)
            }
            val justify = props.attr("w:jc", "w:val")
            val align = when (justify) {
                "center" -> Layout.Alignment.ALIGN_CENTER
                "right", "end" -> Layout.Alignment.ALIGN_OPPOSITE
                else -> Layout.Alignment.ALIGN_NORMAL
            }
            val justified = justify in setOf("both", "distribute", "lowKashida", "mediumKashida", "highKashida", "thaiDistribute")
            val shading = color(props.attr("w:shd", "w:fill"))
            val borders = props.node("w:pBdr")
            val paint = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG or Paint.LINEAR_TEXT_FLAG).apply {
                color = 0xFF000000.toInt()
                textSize = size(mark, rtl)
                typeface = family(font(mark, rtl))
            }
            val tabs = props.nodes.flatMap { it.child("w:tabs")?.elements("w:tab").orEmpty() }
                .filter { it.attr("w:val") != "clear" }.mapNotNull { twips(it.attr("w:pos")) }
            // The layout box: widened on the start side for negative indents, narrowed on the end side by the end indent.
            val areaWidth = width + shift - endIndent
            val x = if (rtl) endIndent else -shift
            val contextual = props.flag("w:contextualSpacing")

            return segments.mapIndexed { index, segment ->
                val text = segment.text
                if (text.isEmpty() || text.last() == '\n') {
                    val start = text.length
                    text.append('​')
                    style(text, start, text.length, mark, rtl)
                }
                val all = text.length
                lineSpacing?.let { text.setSpan(it, 0, all, Spanned.SPAN_INCLUSIVE_INCLUSIVE) }
                val first = firstMargin + shift
                val rest = startIndent + shift
                if (first != 0f || rest != 0f) text.setSpan(LeadingMarginSpan.Standard(first.roundToInt(), rest.roundToInt()), 0, all, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
                // Tab stops count from the container's start; Android counts from where the first line begins.
                val stops = (tabs + generateSequence(defaultTab) { it + defaultTab }.takeWhile { it < width + defaultTab }.toList())
                    .map { it + shift - first }.filter { it > 0.5f }.toMutableList()
                if (hanging != null && hanging > 0) stops += hanging
                for (stop in stops.distinct()) text.setSpan(TabStopSpan.Standard(stop.roundToInt()), 0, all, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
                val layout = StaticLayout.Builder.obtain(text, 0, all, paint, max(1, areaWidth.roundToInt()))
                    .setAlignment(align)
                    .setTextDirection(if (rtl) TextDirectionHeuristics.RTL else TextDirectionHeuristics.LTR)
                    .setIncludePad(false)
                    .setLineSpacing(0f, 1f)
                    .setUseLineSpacingFromFallbacks(false)
                    .setBreakStrategy(Layout.BREAK_STRATEGY_SIMPLE)
                    .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NONE)
                    .setJustificationMode(if (justified) Layout.JUSTIFICATION_MODE_INTER_WORD else Layout.JUSTIFICATION_MODE_NONE)
                    .build()
                ParaBlock(
                    layout, x, areaWidth,
                    before = if (index == 0) before else 0f, after = if (index == segments.size - 1) after else 0f,
                    anchors = segment.anchors, breakBefore = index > 0 || (index == 0 && props.flag("w:pageBreakBefore")),
                    style = styleId, contextual = contextual, shading = shading,
                    top = border(borders?.child("w:top")), bottom = border(borders?.child("w:bottom")),
                    start = border(borders?.child("w:left") ?: borders?.child("w:start")),
                    end = border(borders?.child("w:right") ?: borders?.child("w:end")), rtl = rtl,
                )
            }
        }

        private fun fieldValue(instruction: String): String? {
            val n = numbers ?: return null
            val name = instruction.trim().substringBefore(' ').uppercase()
            return when (name) {
                "PAGE" -> n.page.toString()
                "NUMPAGES", "SECTIONPAGES" -> n.total.toString()
                else -> null
            }
        }

        private fun size(run: Props, complex: Boolean): Float =
            ((if (complex) run.attr("w:szCs", "w:val") ?: run.attr("w:sz", "w:val") else run.attr("w:sz", "w:val"))?.toFloatOrNull() ?: 20f) / 2f

        private fun font(run: Props, complex: Boolean): String? =
            if (complex) run.attr("w:rFonts", "w:cs") ?: run.attr("w:rFonts", "w:ascii") else run.attr("w:rFonts", "w:ascii") ?: run.attr("w:rFonts", "w:hAnsi")

        private fun style(text: SpannableStringBuilder, start: Int, end: Int, run: Props, complex: Boolean) {
            if (start >= end) return
            val bold = if (complex) run.node("w:bCs")?.let { isOn(it.attr("w:val")) } ?: run.flag("w:b") else run.flag("w:b")
            val italic = if (complex) run.node("w:iCs")?.let { isOn(it.attr("w:val")) } ?: run.flag("w:i") else run.flag("w:i")
            val spacing = if (complex) 0f else twips(run.attr("w:spacing", "w:val")) ?: 0f
            val flags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            text.setSpan(RunSpan(size(run, complex), family(font(run, complex)), bold, italic,
                                 run.attr("w:vertAlign", "w:val")?.takeIf { it != "baseline" }, spacing), start, end, flags)
            color(run.attr("w:color", "w:val"))?.let { text.setSpan(ForegroundColorSpan(it), start, end, flags) }
            run.attr("w:u", "w:val")?.let { if (it != "none") text.setSpan(UnderlineSpan(), start, end, flags) }
            if (run.flag("w:strike") || run.flag("w:dstrike")) text.setSpan(StrikethroughSpan(), start, end, flags)
            val highlight = run.attr("w:highlight", "w:val")?.let { highlights[it]?.toInt() } ?: color(run.attr("w:shd", "w:fill"))
            highlight?.let { text.setSpan(BackgroundColorSpan(it), start, end, flags) }
        }

        // Lists

        private fun numberingLevel(numPr: XNode?, props: Props): XNode? {
            val numId = numPr?.child("w:numId")?.attr("w:val") ?: return null
            if (numId == "0") return null
            val level = numPr.child("w:ilvl")?.attr("w:val")?.toIntOrNull() ?: props.attr("w:numPr", "w:ilvl")?.toIntOrNull() ?: 0
            val num = numbering?.elements("w:num")?.firstOrNull { it.attr("w:numId") == numId } ?: return null
            val override = num.elements("w:lvlOverride").firstOrNull { it.attr("w:ilvl") == level.toString() }
            override?.child("w:lvl")?.let { return it }
            val abstractId = num.child("w:abstractNumId")?.attr("w:val") ?: return null
            val abstract = numbering.elements("w:abstractNum").firstOrNull { it.attr("w:abstractNumId") == abstractId } ?: return null
            return abstract.elements("w:lvl").firstOrNull { it.attr("w:ilvl") == level.toString() }
        }

        private fun label(level: XNode, numPr: XNode?): String? {
            val numId = numPr?.child("w:numId")?.attr("w:val") ?: return null
            val depth = level.attr("w:ilvl")?.toIntOrNull() ?: 0
            val num = numbering?.elements("w:num")?.firstOrNull { it.attr("w:numId") == numId }
            val abstractId = num?.child("w:abstractNumId")?.attr("w:val")
            val levels = numbering?.elements("w:abstractNum")?.firstOrNull { it.attr("w:abstractNumId") == abstractId }?.elements("w:lvl").orEmpty()
            fun startOf(d: Int): Int {
                num?.elements("w:lvlOverride")?.firstOrNull { it.attr("w:ilvl") == d.toString() }?.child("w:startOverride")?.attr("w:val")?.toIntOrNull()?.let { return it }
                return levels.firstOrNull { it.attr("w:ilvl") == d.toString() }?.child("w:start")?.attr("w:val")?.toIntOrNull() ?: 1
            }
            val counts = counters.getOrPut(numId) { IntArray(9) { startOf(it) - 1 } }
            if (depth in 0..8) {
                counts[depth]++
                for (d in depth + 1 until 9) counts[d] = startOf(d) - 1
            }
            val format = level.child("w:numFmt")?.attr("w:val") ?: "decimal"
            if (format == "none") return null
            var text = level.child("w:lvlText")?.attr("w:val") ?: return null
            if (format == "bullet") {
                text = text.map { if (it.code in 0xF000..0xF0FF) symbol(it.code) else it.toString() }.joinToString("")
            } else {
                for (d in 0..8) {
                    if (!text.contains("%${d + 1}")) continue
                    val f = if (d == depth) format else levels.firstOrNull { it.attr("w:ilvl") == d.toString() }?.child("w:numFmt")?.attr("w:val") ?: "decimal"
                    text = text.replace("%${d + 1}", formatNumber(max(1, counts[d]), f))
                }
            }
            return text + when (level.child("w:suff")?.attr("w:val")) { "space" -> " "; "nothing" -> ""; else -> "\t" }
        }

        // Pictures and shapes

        private fun graphic(drawing: XNode, s: Section): Triple<Graphic, Float, Float>? {
            val extent = drawing.child("wp:extent")
            val w = emus(extent?.attr("cx")) ?: return null
            val h = emus(extent?.attr("cy")) ?: return null
            val data = drawing.descendants("a:graphicData").firstOrNull() ?: return null
            val element = data.children.firstOrNull { !it.isText } ?: return null
            val graphic = element(element, w, h, s) ?: return null
            return Triple(graphic, w, h)
        }

        private fun element(node: XNode, w: Float, h: Float, s: Section): Graphic? = when (node.name) {
            "pic:pic" -> picture(node, w, h)
            "wps:wsp" -> shape(node, s)
            "wpg:wgp", "wpg:grpSp" -> group(node, w, h, s)
            "mc:AlternateContent" -> (node.child("mc:Choice") ?: node.child("mc:Fallback"))?.children?.firstOrNull { !it.isText }?.let { element(it, w, h, s) }
            else -> null
        }

        private fun picture(node: XNode, w: Float, h: Float): Graphic? {
            val id = node.descendants("a:blip").firstOrNull()?.attr("r:embed") ?: return null
            val bitmap = bitmap(part.rels[id] ?: return null, w, h) ?: return null
            val crop = node.descendants("a:srcRect").firstOrNull()?.let { r ->
                fun f(name: String) = (r.attr(name)?.toFloatOrNull() ?: 0f) / 100000f
                RectF(f("l"), f("t"), f("r"), f("b")).takeIf { it.left != 0f || it.top != 0f || it.right != 0f || it.bottom != 0f }
            }
            return PictureGraphic(bitmap, crop)
        }

        private fun solid(node: XNode?): Int? {
            if (node == null || node.child("a:noFill") != null) return null
            return color(node.child("a:solidFill")?.child("a:srgbClr")?.attr("val"))
        }

        private fun shape(node: XNode, s: Section): Graphic? {
            val spPr = node.child("wps:spPr")
            val geometry = spPr?.child("a:prstGeom")?.attr("prst") ?: "rect"
            val ln = spPr?.child("a:ln")
            val lineColor = solid(ln)
            val line = lineColor?.let { Border(max(0.25f, emus(ln?.attr("w")) ?: 0.75f), it) }
            val flip = spPr?.child("a:xfrm")?.attr("flipH") == "1"
            val body = node.child("wps:bodyPr")
            val insets = RectF(emus(body?.attr("lIns")) ?: 7.2f, emus(body?.attr("tIns")) ?: 3.6f, emus(body?.attr("rIns")) ?: 7.2f, emus(body?.attr("bIns")) ?: 3.6f)
            val content = node.child("wps:txbx")?.child("w:txbxContent")
            val text = content?.let { c -> { width: Float -> blocks(c, width, emptyList(), s) } }
            val fillColor = solid(spPr)
            if (fillColor == null && line == null && text == null) return null
            return Shape(geometry, fillColor, line, flip, text, insets, this@Renderer) { s }
        }

        private fun frame(node: XNode?): RectF? {
            val xfrm = node?.child("a:xfrm") ?: return null
            val x = emus(xfrm.child("a:off")?.attr("x")) ?: 0f
            val y = emus(xfrm.child("a:off")?.attr("y")) ?: 0f
            val w = emus(xfrm.child("a:ext")?.attr("cx")) ?: return null
            val h = emus(xfrm.child("a:ext")?.attr("cy")) ?: return null
            return RectF(x, y, x + w, y + h)
        }

        private fun group(node: XNode, w: Float, h: Float, s: Section): Graphic? {
            val xfrm = node.child("wpg:grpSpPr")?.child("a:xfrm")
            val cx = emus(xfrm?.child("a:chOff")?.attr("x")) ?: 0f
            val cy = emus(xfrm?.child("a:chOff")?.attr("y")) ?: 0f
            val space = RectF(cx, cy, cx + (emus(xfrm?.child("a:chExt")?.attr("cx")) ?: w), cy + (emus(xfrm?.child("a:chExt")?.attr("cy")) ?: h))
            val children = node.children.mapNotNull { child ->
                val rect = when (child.name) {
                    "wps:wsp" -> frame(child.child("wps:spPr"))
                    "pic:pic" -> frame(child.child("pic:spPr"))
                    "wpg:grpSp" -> frame(child.child("wpg:grpSpPr"))
                    else -> null
                } ?: return@mapNotNull null
                element(child, rect.width(), rect.height(), s)?.let { it to rect }
            }
            return if (children.isEmpty()) null else Group(children, space)
        }

        private fun anchor(node: XNode, graphic: Graphic, w: Float, h: Float): Anchor {
            val horizontal = node.child("wp:positionH")
            val vertical = node.child("wp:positionV")
            val simple = node.attr("simplePos") == "1"
            val point = node.child("wp:simplePos")
            return Anchor(
                graphic, w, h, behind = node.attr("behindDoc") == "1",
                horizontalFrom = if (simple) "page" else horizontal?.attr("relativeFrom") ?: "column",
                horizontalOffset = if (simple) emus(point?.attr("x")) ?: 0f else emus(horizontal?.child("wp:posOffset")?.innerText),
                horizontalAlign = horizontal?.child("wp:align")?.innerText?.trim(),
                verticalFrom = if (simple) "page" else vertical?.attr("relativeFrom") ?: "paragraph",
                verticalOffset = if (simple) emus(point?.attr("y")) ?: 0f else emus(vertical?.child("wp:posOffset")?.innerText),
                verticalAlign = vertical?.child("wp:align")?.innerText?.trim(),
            )
        }

        /** Older pictures and text boxes (VML), still common in letterheads made with old versions of Word. */
        private fun vml(node: XNode, s: Section): VmlResult? {
            val shape = node.descendants().firstOrNull { it.name == "v:shape" || it.name == "v:rect" || it.name == "v:roundrect" || it.name == "v:oval" } ?: return null
            val style = (shape.attr("style") ?: "").split(';').mapNotNull { pair ->
                val key = pair.substringBefore(':', "").trim().lowercase()
                if (key.isEmpty()) null else key to pair.substringAfter(':').trim()
            }.toMap()
            val w = measure(style["width"], 1f)?.let { if (style["width"]?.toFloatOrNull() != null) it * 0.75f else it } ?: return null
            val h = measure(style["height"], 1f)?.let { if (style["height"]?.toFloatOrNull() != null) it * 0.75f else it } ?: return null
            val image = shape.descendants("v:imagedata").firstOrNull()?.attr("r:id")?.let { part.rels[it] }
            val textbox = shape.descendants("w:txbxContent").firstOrNull()
            val fillColor = shape.attr("fillcolor")?.removePrefix("#")?.takeIf { shape.attr("filled") != "f" && it.length == 6 }?.let(::color)
            val graphic: Graphic = when {
                image != null -> bitmap(image, w, h)?.let { PictureGraphic(it, null) } ?: return null
                textbox != null || fillColor != null -> Shape("rect", fillColor, null, false,
                    textbox?.let { c -> { width: Float -> blocks(c, width, emptyList(), s) } }, RectF(7.2f, 3.6f, 7.2f, 3.6f), this@Renderer) { s }
                else -> return null
            }
            if (style["position"] != "absolute") return VmlResult(graphic, w, h, null)
            fun relative(key: String, fallback: String) = when (style[key]) {
                "page" -> "page"; "margin" -> "margin"; "char", "line" -> if (key.contains("horizontal")) "character" else "line"
                else -> fallback
            }
            val anchor = Anchor(
                graphic, w, h, behind = (style["z-index"]?.toIntOrNull() ?: 0) < 0,
                horizontalFrom = relative("mso-position-horizontal-relative", "column"),
                horizontalOffset = measure(style["margin-left"], 1f).takeIf { style["mso-position-horizontal"] == null },
                horizontalAlign = style["mso-position-horizontal"],
                verticalFrom = relative("mso-position-vertical-relative", "paragraph"),
                verticalOffset = measure(style["margin-top"], 1f).takeIf { style["mso-position-vertical"] == null },
                verticalAlign = style["mso-position-vertical"],
            )
            return VmlResult(graphic, w, h, anchor)
        }

        // Tables

        private fun table(node: XNode, width: Float, s: Section): TableBlock? {
            val tblPr = node.child("w:tblPr")
            val styleNodes = tableStyle(tblPr)
            val props = Props(styleNodes.mapNotNull { it.child("w:tblPr") } + listOfNotNull(tblPr))
            val rtl = props.flag("w:bidiVisual")
            val rows = node.elements("w:tr")
            if (rows.isEmpty()) return null
            var grid = node.child("w:tblGrid")?.elements("w:gridCol")?.map { twips(it.attr("w:w")) ?: 0f }.orEmpty()
            val columns = max(grid.size, rows.maxOf { r -> r.elements("w:tc").sumOf { (it.child("w:tcPr")?.child("w:gridSpan")?.attr("w:val")?.toIntOrNull() ?: 1) } })
            if (grid.size < columns || grid.sum() <= 0f) grid = List(columns) { width / columns }
            val total = grid.sum()
            if (total > width * 1.02f && props.attr("w:tblLayout", "w:type") != "fixed") grid = grid.map { it * width / total }
            val tableWidth = grid.sum()
            val indent = twips(props.attr("w:tblInd", "w:w")) ?: 0f
            val start = when (props.attr("w:jc", "w:val")) {
                "center" -> (width - tableWidth) / 2
                "right", "end" -> width - tableWidth
                else -> indent
            }
            val x = if (rtl) width - tableWidth - start else start
            val margins = props.node("w:tblCellMar")
            fun margin(m: XNode?, vararg names: String, fallback: Float) = names.firstNotNullOfOrNull { n -> m?.child(n)?.let { twips(it.attr("w:w")) } } ?: fallback
            val padLeft = margin(margins, "w:left", "w:start", fallback = 5.4f)
            val padRight = margin(margins, "w:right", "w:end", fallback = 5.4f)
            val padTop = margin(margins, "w:top", fallback = 0f)
            val padBottom = margin(margins, "w:bottom", fallback = 0f)
            val borders = props.node("w:tblBorders")
            fun tableBorder(vararg names: String) = names.firstNotNullOfOrNull { borders?.child(it) }?.let { border(it) }

            // Which grid column each cell starts at, to see vertical merges.
            val starts = rows.map { row ->
                var col = row.child("w:trPr")?.child("w:gridBefore")?.attr("w:val")?.toIntOrNull() ?: 0
                row.elements("w:tc").map { cell -> col.also { col += cell.child("w:tcPr")?.child("w:gridSpan")?.attr("w:val")?.toIntOrNull() ?: 1 } }
            }
            fun merge(r: Int, col: Int): String? {
                val cells = rows.getOrNull(r)?.elements("w:tc") ?: return null
                val i = starts[r].indexOf(col)
                if (i < 0) return null
                val v = cells[i].child("w:tcPr")?.child("w:vMerge") ?: return null
                return v.attr("w:val") ?: "continue"
            }

            val laid = rows.mapIndexed { r, row ->
                val cells = row.elements("w:tc")
                val laidCells = cells.mapIndexed { i, cell ->
                    val tcPr = cell.child("w:tcPr")
                    val span = tcPr?.child("w:gridSpan")?.attr("w:val")?.toIntOrNull() ?: 1
                    val col = starts[r][i]
                    val logicalX = grid.take(col).sum()
                    val w = grid.drop(col).take(span).sum()
                    val cellX = if (rtl) tableWidth - logicalX - w else logicalX
                    val cellMargins = tcPr?.child("w:tcMar")
                    val padding = RectF(margin(cellMargins, "w:left", "w:start", fallback = padLeft), margin(cellMargins, "w:top", fallback = padTop),
                                        margin(cellMargins, "w:right", "w:end", fallback = padRight), margin(cellMargins, "w:bottom", fallback = padBottom))
                    if (rtl) padding.set(padding.right, padding.top, padding.left, padding.bottom)
                    val merged = merge(r, col) == "continue"
                    val continues = merge(r + 1, col) == "continue"
                    val own = tcPr?.child("w:tcBorders")
                    fun side(vararg names: String) = names.firstNotNullOfOrNull { own?.child(it) }
                    val firstCol = col == 0
                    val lastCol = col + span >= columns
                    val startBorder = side("w:left", "w:start")?.let(::border) ?: if (firstCol) tableBorder("w:left", "w:start") else tableBorder("w:insideV")
                    val endBorder = side("w:right", "w:end")?.let(::border) ?: if (lastCol) tableBorder("w:right", "w:end") else tableBorder("w:insideV")
                    val blocks = if (merged) emptyList() else blocks(cell, max(1f, w - padding.left - padding.right), styleNodes, s)
                    Cell(
                        blocks, cellX, w, padding, color(tcPr?.child("w:shd")?.attr("w:fill")),
                        left = if (rtl) endBorder else startBorder, right = if (rtl) startBorder else endBorder,
                        top = if (merged) null else side("w:top")?.let(::border) ?: if (r == 0) tableBorder("w:top") else tableBorder("w:insideH"),
                        bottom = if (continues) null else side("w:bottom")?.let(::border) ?: if (r == rows.size - 1) tableBorder("w:bottom") else tableBorder("w:insideH"),
                        vAlign = tcPr?.child("w:vAlign")?.attr("w:val"), merged = merged, content = stackHeight(blocks),
                    )
                }
                val trHeight = row.child("w:trPr")?.child("w:trHeight")
                val wanted = twips(trHeight?.attr("w:val")) ?: 0f
                val natural = laidCells.filter { !it.merged }.maxOfOrNull { it.content + it.padding.top + it.padding.bottom } ?: 0f
                Row(laidCells, if (trHeight?.attr("w:hRule") == "exact") wanted else max(wanted, natural))
            }
            return TableBlock(laid, x)
        }
    }

    private class VmlResult(val graphic: Graphic, val width: Float, val height: Float, val anchor: Anchor?) {
        operator fun component1() = graphic
        operator fun component2() = width
        operator fun component3() = height
        operator fun component4() = anchor
    }
}

/** Symbol and Wingdings bullets live in the private-use area; these are their usual look. */
private fun symbol(code: Int): String = when (code) {
    0xF0A7 -> "▪"
    0xF0D8 -> "➢"
    0xF0FC -> "✓"
    0xF076 -> "❖"
    0xF0A8 -> "□"
    0xF06F -> "o"
    else -> "•"
}

private fun formatNumber(n: Int, format: String): String = when (format) {
    "lowerLetter" -> letters(n).lowercase()
    "upperLetter" -> letters(n)
    "lowerRoman" -> roman(n).lowercase()
    "upperRoman" -> roman(n)
    "arabicAlpha" -> "أبتثجحخدذرزسشصضطظعغفقكلمنهوي".let { it[(n - 1) % it.length].toString() }
    "arabicAbjad" -> "أبجدهوزحطيكلمنسعفصقرشتثخذضظغ".let { it[(n - 1) % it.length].toString() }
    "hindiNumbers" -> n.toString().map { '٠' + (it - '0') }.joinToString("")
    "decimalZero" -> if (n < 10) "0$n" else n.toString()
    else -> n.toString()
}

private fun letters(n: Int): String = ('A' + (n - 1) % 26).toString().repeat((n - 1) / 26 + 1)

private fun roman(n: Int): String {
    val values = intArrayOf(1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1)
    val symbols = arrayOf("M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I")
    var rest = n
    val out = StringBuilder()
    for (i in values.indices) while (rest >= values[i]) { out.append(symbols[i]); rest -= values[i] }
    return out.toString()
}
