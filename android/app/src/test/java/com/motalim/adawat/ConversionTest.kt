package com.motalim.adawat

import com.motalim.adawat.core.AdawatException
import com.motalim.adawat.docs.SheetOps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipFile

/** Documents, spreadsheets and subtitles: the conversions written in plain Kotlin. */
class ConversionTest : AdawatTest() {
    // Spreadsheets

    private val table = "name,age,city\nAli,30,Cairo\nMona,28,\"Giza, west\"\n"
    private val cells = listOf(listOf("name", "age", "city"), listOf("Ali", "30", "Cairo"), listOf("Mona", "28", "Giza, west"))

    /** Cells as text; a whole number reads the same whether it was kept as a number or as text. */
    private fun cells(file: File) = SheetOps.read(file)[0].rows.map { row ->
        row.map { cell -> if (cell is Double && cell == Math.floor(cell)) cell.toLong().toString() else cell?.toString() ?: "" }
    }

    @Test
    fun aTableKeepsItsCells() {
        val csv = file("table.csv", table)
        for (ext in listOf("xlsx", "ods", "tsv")) assertEquals(ext, cells, cells(runOne("sheet.$ext", csv)))
    }

    @Test
    fun excelBecomesCsvAgain() {
        val excel = runOne("sheet.xlsx", file("table.csv", table))
        val csv = runOne("sheet.csv", excel)
        assertEquals(cells, cells(csv))
        assertTrue(csv.readText().contains("\"Giza, west\""))
    }

    @Test
    fun aTableBecomesAWebPage() {
        val html = runOne("sheet.html", file("table.csv", table)).readText()
        assertTrue(html.contains("<table"))
        assertTrue(html.contains("Giza, west"))
    }

    // Subtitles

    private val srt = "1\n00:00:01,000 --> 00:00:02,500\nHello there\n\n2\n00:01:03,250 --> 00:01:05,000\nSecond line\nstill the second\n"

    @Test
    fun srtBecomesWebVttAndBack() {
        val vttFile = runOne("subtitle.vtt", file("film.srt", srt))
        val vtt = vttFile.readText()
        assertTrue(vtt.startsWith("WEBVTT"))
        assertTrue(vtt.contains("00:00:01.000 --> 00:00:02.500"))
        assertTrue(vtt.contains("Second line\nstill the second"))
        val back = runOne("subtitle.srt", vttFile).readText()
        assertTrue(back.contains("1\n00:00:01,000 --> 00:00:02,500\nHello there"))
        assertTrue(back.contains("2\n00:01:03,250 --> 00:01:05,000\nSecond line"))
    }

    @Test
    fun textDropsTheTimings() {
        val text = runOne("subtitle.txt", file("film.srt", srt)).readText()
        assertFalse(text.contains("-->"))
        assertTrue(text.contains("Hello there"))
        assertTrue(text.contains("still the second"))
    }

    @Test
    fun aFileWithoutCuesIsReportedInWords() {
        val empty = file("empty.srt", "nothing here\n")
        val error = assertThrows(AdawatException::class.java) { run("subtitle.vtt", empty) }
        assertTrue(error.message.contains("empty.srt"))
    }

    // Documents

    private val note = "# Travel notes\n\nHello **world**, this is a note.\n\n- one\n- two\n"

    @Test
    fun markdownBecomesWordAndBack() {
        val word = runOne("doc.docx", file("note.md", note))
        assertEquals("note.docx", word.name)
        val back = runOne("doc.md", word).readText()
        assertTrue(back, back.contains("# Travel notes"))
        assertTrue(back, back.contains("**world**"))
        assertTrue(back, back.contains("one"))
    }

    @Test
    fun markdownBecomesHtmlWithItsHeading() {
        val html = runOne("doc.html", file("note.md", note)).readText()
        assertTrue(html.contains("<h1"))
        assertTrue(html.contains("Travel notes"))
        assertTrue(html.contains("<li"))
    }

    @Test
    fun markdownBecomesPlainText() {
        val text = runOne("doc.txt", file("note.md", note)).readText()
        assertTrue(text.contains("Travel notes"))
        assertTrue(text.contains("Hello world, this is a note."))
        assertFalse(text.contains("**"))
    }

    @Test
    fun markdownBecomesAPackagedDocument() {
        for ((ext, entry) in listOf("epub" to "mimetype", "odt" to "content.xml")) {
            val output = runOne("doc.$ext", file("note.md", note))
            ZipFile(output).use { zip -> assertTrue("$ext has no $entry", zip.getEntry(entry) != null) }
            val text = runOne("doc.txt", output).readText()
            assertTrue("$ext: $text", text.contains("Travel notes"))
        }
    }

    @Test
    fun arabicTextSurvivesWord() {
        val word = runOne("doc.docx", file("arabic.md", "# عنوان\n\nمرحبا بالعالم.\n"))
        val text = runOne("doc.txt", word).readText()
        assertTrue(text.contains("عنوان"))
        assertTrue(text.contains("مرحبا بالعالم."))
    }
}
