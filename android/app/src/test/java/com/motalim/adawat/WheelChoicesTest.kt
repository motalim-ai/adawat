package com.motalim.adawat

import com.motalim.adawat.core.Catalog
import com.motalim.adawat.core.Operation
import com.motalim.adawat.core.WheelMode
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The wheel offers what Tests/wheel-choices.json says, in that order. The Mac, Windows and Linux tests read the same file. */
class WheelChoicesTest : AdawatTest() {
    private val spec = JSONObject(File("../../Tests/wheel-choices.json").readText())

    private fun JSONArray.strings() = (0 until length()).map { getString(it) }

    private fun JSONObject.names(key: String) = optJSONArray(key)?.strings() ?: emptyList()

    @Test
    fun everyCase() {
        val cases = spec.getJSONArray("cases")
        var checked = 0
        for (number in 0 until cases.length()) {
            val case = cases.getJSONObject(number)
            if ("android" in case.names("not")) continue
            val home = File(folder, "case $number").apply { mkdirs() }
            val files = case.getJSONArray("files").strings().map { File(home, it).apply { writeText("") } }
            val name = case.getString("name")
            check(name, "Convert", case.getJSONArray("convert"), Catalog.forMode(WheelMode.Convert, files))
            check(name, "Tools", case.getJSONArray("tools"), Catalog.forMode(WheelMode.Tools, files))
            check(name, "Actions", spec.getJSONArray("actions"), Catalog.forMode(WheelMode.Actions, files))
            checked++
        }
        assertTrue("only $checked cases were for Android", checked > 20)
    }

    private fun check(name: String, wheel: String, expected: JSONArray, offered: List<Operation>) {
        val required = mutableListOf<String>()
        val optional = mutableSetOf<String>()
        for (index in 0 until expected.length()) {
            val entry = expected.get(index)
            if (entry is String) { required += entry; continue }
            entry as JSONObject
            if (entry.has("only") && "android" !in entry.names("only")) continue
            if ("android" in entry.names("not")) continue
            // optional is true, or the platforms where the choice depends on the machine.
            val mayBeMissing = entry.opt("optional") == true || "android" in entry.names("optional")
            if (mayBeMissing) optional += entry.getString("id") else required += entry.getString("id")
        }
        // Choices that depend on the phone may be there or not; everything else has to match, in petal order.
        assertEquals("$name: the $wheel wheel", required, offered.map { it.id }.filter { it !in optional })
        assertEquals("$name: the $wheel wheel repeats a choice", offered.size, offered.map { it.id }.toSet().size)
    }

    @Test
    fun printIsForPhotosAndPdfsOnly() {
        fun actions(vararg names: String) = Catalog.forMode(WheelMode.Actions, names.map { file(it) }).map { it.id }
        assertTrue("action.print" in actions("photo.jpg"))
        assertTrue("action.print" in actions("report.pdf"))
        assertTrue("action.print" in actions("photo.jpg", "report.pdf"))
        assertTrue("action.print" !in actions("clip.mp4"))
        assertTrue("action.print" !in actions("photo.jpg", "note.md"))
    }
}
