package com.motalim.adawat

import com.motalim.adawat.core.Catalog
import com.motalim.adawat.core.OperationContext
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import java.io.File

/**
 * Tests that run on this computer, with no phone (./gradlew testDebugUnitTest). They reach what is written in plain
 * Kotlin: the wheel's choices and the document, spreadsheet and subtitle conversions. Photos, video, PDF and archives
 * go through Android itself or the NDK, and need a phone.
 */
abstract class AdawatTest {
    /** A folder of its own for each test, removed afterwards. */
    protected lateinit var folder: File

    @Before
    fun makeFolder() {
        folder = File(System.getProperty("java.io.tmpdir"), "adawat-tests/${System.nanoTime()}").apply { mkdirs() }
    }

    @After
    fun removeFolder() {
        folder.deleteRecursively()
    }

    protected fun file(name: String, text: String = "") = File(folder, name).apply { writeText(text) }

    /** Runs a wheel choice by its id, as a tap on its petal would; results land in a folder named out. */
    protected fun run(id: String, vararg files: File): List<File> = runBlocking {
        val operation = Catalog.find(id, files.toList()) ?: error("The wheel has no $id for ${files.joinToString { it.name }}")
        operation.run(files.toList(), OperationContext(File(folder, "out").apply { mkdirs() }))
    }

    protected fun runOne(id: String, vararg files: File): File = run(id, *files).single().also { check(it.isFile) { "$id reported ${it.name}, which is not there" } }
}
