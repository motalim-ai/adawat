package com.motalim.adawat

import androidx.compose.ui.geometry.Offset
import com.motalim.adawat.core.FileKind
import com.motalim.adawat.core.FileKinds
import com.motalim.adawat.core.OperationContext
import com.motalim.adawat.wheel.WheelGeometry
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** What kind a file is, what its results are called, where a finger lands on the wheel, and the translations. */
class FilesTest : AdawatTest() {
    @Test
    fun kindComesFromTheExtension() {
        val kinds = mapOf(
            "photo.JPG" to FileKind.Image, "photo.heic" to FileKind.Image, "report.pdf" to FileKind.Pdf, "clip.mkv" to FileKind.Video,
            "voice.opus" to FileKind.Audio, "letter.docx" to FileKind.Document, "table.csv" to FileKind.Spreadsheet,
            "deck.pptx" to FileKind.Presentation, "film.vtt" to FileKind.Subtitle, "box.tar.gz" to FileKind.Archive,
            "data.xyz" to FileKind.Other, "no extension" to FileKind.Other,
        )
        for ((name, kind) in kinds) assertEquals(name, kind, FileKinds.of(File(folder, name)))
        assertEquals("tgz", FileKinds.ext(File("a.TAR.GZ")))
        assertEquals("jpeg", FileKinds.ext(File("Photo.JPEG")))
        assertEquals("", FileKinds.ext(File("README")))
    }

    @Test
    fun aResultNeverReplacesAFileThatIsThere() {
        val context = OperationContext(folder)
        val source = File("holiday.jpg")
        val first = context.pathFor(source, "png")
        assertEquals("holiday.png", first.name)
        first.writeText("")
        assertEquals("holiday 2.png", context.pathFor(source, "png").name)
        assertEquals("holiday rotated.jpg", context.pathFor(source, "jpg", "rotated").name)
    }

    @Test
    fun thePetalUnderTheFingerIsTheOneDrawnThere() {
        for (count in listOf(1, 2, 6, 9, 11)) {
            for (index in 0 until count) assertEquals("$index of $count", index, WheelGeometry.index(WheelGeometry.position(index, count), count))
            assertNull(WheelGeometry.index(Offset(WheelGeometry.SIZE / 2, WheelGeometry.SIZE / 2), count))
            assertTrue(WheelGeometry.isCenter(Offset(WheelGeometry.SIZE / 2, WheelGeometry.SIZE / 2)))
        }
        assertNull("a touch well outside the wheel", WheelGeometry.index(Offset(0f, 0f), 6))
    }

    /** The Arabic text comes from two files: the one shared with Windows and Linux, and Android's own additions. */
    @Test
    fun everyTranslationSaysSomething() {
        val shared = JSONObject(File("../../windows/shared/strings.ar.json").readText())
        val own = JSONObject(File("src/main/assets/android.ar.json").readText())
        assertTrue(shared.length() > 400)
        assertTrue(own.length() > 100)
        for (table in listOf(shared, own)) {
            for (english in table.keys()) assertTrue("\"$english\" has no Arabic", table.getString(english).isNotBlank())
        }
        assertEquals("إلغاء", shared.getString("Cancel"))
        assertEquals("أُلغي", own.getString("Cancelled"))
    }
}
