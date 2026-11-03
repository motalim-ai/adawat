package com.motalim.adawat.core

import com.motalim.adawat.docs.DocumentOps
import com.motalim.adawat.docs.DocumentTarget
import com.motalim.adawat.docs.SheetOps
import com.motalim.adawat.docs.SubtitleOps
import com.motalim.adawat.media.AudioOps
import com.motalim.adawat.media.MediaFormatChoice
import com.motalim.adawat.media.MediaTools
import com.motalim.adawat.media.Visualizer
import com.motalim.adawat.media.VideoOps
import com.motalim.adawat.ops.Adjustments
import com.motalim.adawat.ops.ArchiveOps
import com.motalim.adawat.ops.AnnotationRenderer
import com.motalim.adawat.ops.FileActions
import com.motalim.adawat.ops.PhotoMetadata
import com.motalim.adawat.ops.ImageFormat
import com.motalim.adawat.ops.ImageOps
import com.motalim.adawat.ops.ImageTools
import com.motalim.adawat.ops.PdfOps
import com.motalim.adawat.ops.QrCode
import java.io.File

/** Decides which wheel choices fit the shared files. Mirrors the desktop catalog, choice for choice, as far as Android can go. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
object Catalog {
    /** Material Icons Round code points, matched to the Segoe icons the Windows app draws. */
    object Icons {
        const val Photo = ''; const val Document = ''; const val Film = ''; const val Audio = ''
        const val Archive = ''; const val Compress = ''; const val Metadata = ''; const val Edit = ''
        const val Annotate = ''; const val Background = ''; const val Crop = ''; const val Redact = ''
        const val Rotate = ''; const val Text = ''; const val Qr = ''; const val Pdf = ''
        const val Collage = ''; const val Merge = ''; const val Organize = ''; const val Split = ''
        const val Trim = ''; const val Speed = ''; const val Camera = ''; const val Join = ''
        const val Mute = ''; const val Volume = ''; const val Waveform = ''; const val Channels = ''
        const val Bleep = ''; const val Silence = ''; const val Share = ''; const val Copy = ''
        const val Save = ''; const val OpenWith = ''; const val Info = ''; const val Print = ''
        const val Extract = ''; const val Folder = ''
    }

    fun forMode(mode: WheelMode, files: List<File>): List<Operation> {
        if (files.isEmpty()) return emptyList()
        return when (mode) {
            WheelMode.Convert -> conversions(files)
            WheelMode.Tools -> tools(files)
            WheelMode.Actions -> actions(files)
        }
    }

    fun find(id: String, files: List<File>): Operation? =
        WheelMode.entries.asSequence().flatMap { forMode(it, files) }.firstOrNull { it.id == id }

    // Convert

    private fun conversions(files: List<File>): List<Operation> = when (files.commonKind()) {
        FileKind.Image -> {
            val sources = files.map { ImageFormat.of(it) }.toSet()
            val ops = ImageFormat.all
                .filter { format -> !(sources.size == 1 && format in sources) && format.canWrite }
                .map { format ->
                    Operation("image.${format.ext}", "To ${format.title}", Icons.Photo, { f, c -> ImageOps.convert(f, format, c) }, badge = format.title)
                }
            ops + Operation("image.pdf", "To PDF", Icons.Pdf, ImageOps::makePdf, badge = "PDF")
        }
        FileKind.Pdf -> listOf(
            Operation("pdf.docx", "To Word", Icons.Document, { f, c -> DocumentOps.convert(f, DocumentTarget.Docx, c) }, badge = "DOCX"),
            Operation("pdf.pptx", "To PowerPoint", Icons.Document, PdfOps::toPowerPoint, badge = "PPTX"),
            Operation("pdf.epub", "To EPUB", Icons.Document, { f, c -> DocumentOps.convert(f, DocumentTarget.Epub, c) }, badge = "EPUB"),
            Operation("pdf.md", "To Markdown", Icons.Document, PdfOps::toMarkdown, badge = "MD"),
            Operation("pdf.png", "Pages to PNG", Icons.Photo, { f, c -> PdfOps.pagesToPictures(f, ImageFormat.Png, c) }, badge = "PNG"),
            Operation("pdf.jpg", "Pages to JPEG", Icons.Photo, { f, c -> PdfOps.pagesToPictures(f, ImageFormat.Jpeg, c) }, badge = "JPG"),
            Operation("pdf.txt", "To Text", Icons.Text, PdfOps::toText, badge = "TXT"),
            Operation("pdf.xlsx", "To Excel", Icons.Document, PdfOps::toExcel, badge = "XLSX"),
        )
        FileKind.Document -> {
            val sources = files.map { when (it.ext) { "markdown" -> "md"; "htm" -> "html"; else -> it.ext } }.toSet()
            DocumentTarget.entries.filter { !(sources.size == 1 && it.ext in sources) }.map { target ->
                Operation("doc.${target.ext}", "To ${target.title}", Icons.Document, { f, c -> DocumentOps.convert(f, target, c) }, badge = target.title)
            }
        }
        FileKind.Spreadsheet -> {
            val sources = files.map { it.ext }.toSet()
            SheetOps.targets.filter { !(sources.size == 1 && it in sources) }.map { target ->
                Operation("sheet.$target", "To ${SheetOps.title(target)}", Icons.Document, { f, c -> SheetOps.convert(f, target, c) }, badge = SheetOps.title(target))
            }
        }
        FileKind.Subtitle -> {
            val sources = files.map { it.ext }.toSet()
            SubtitleOps.targets.filter { !(sources.size == 1 && it in sources) }.map { target ->
                Operation("subtitle.$target", "To ${SubtitleOps.title(target)}", Icons.Text, { f, c -> SubtitleOps.convert(f, target, c) }, badge = SubtitleOps.title(target))
            }
        }
        FileKind.Archive -> {
            val current = if (files.size == 1) ArchiveOps.formatOf(files[0]) else null
            listOf("zip", "tar", "tgz").filter { it != current }.map { format ->
                Operation("archive.to-$format", "To ${ArchiveOps.title(format)}", Icons.Archive, { f, c -> ArchiveOps.convert(f, format, c) }, badge = ArchiveOps.title(format))
            }
        }
        FileKind.Video -> MediaFormatChoice.video.filter { it.ext != files[0].ext || files.size > 1 }.map(::mediaConversion)
        FileKind.Audio -> MediaFormatChoice.audio.filter { it.ext != files[0].ext || files.size > 1 }.map(::mediaConversion)
        else -> {
            // Mixed selections, and files Adawat has no converter for, can always be packed.
            val formats = mutableListOf("zip", "tar", "tgz")
            if (files.size == 1) formats += "gz"
            formats.map { format ->
                Operation("archive.$format", "To ${ArchiveOps.title(format)}", Icons.Archive, { f, c -> ArchiveOps.pack(f, format, c) }, badge = ArchiveOps.title(format))
            }
        }
    }

    private fun mediaConversion(format: MediaFormatChoice) =
        Operation("media.${format.ext}", "To ${format.title}", if (format.audioOnly) Icons.Audio else Icons.Film,
                  { f, c -> VideoOps.convert(f, format, c) }, badge = format.title)

    // Tools

    private fun tool(id: String, title: String, short: String?, icon: Char, run: OperationWork, window: String? = null,
                     producesFiles: Boolean = true) = Operation(id, title, icon, run, short = short, window = window, producesFiles = producesFiles)

    private fun tools(files: List<File>): List<Operation> {
        val kinds = files.kinds()
        val single = files.size == 1
        val ops = mutableListOf<Operation>()
        if (kinds == setOf(FileKind.Image)) {
            ops += tool("image.compress", "Compress", null, Icons.Compress, { f, c -> ImageTools.compress(f, c) }, "compress")
            ops += tool("image.metadata", "Edit Metadata", "Metadata", Icons.Metadata, PhotoMetadata::save, if (single) "metadata" else null)
            if (single) {
                ops += tool("image.edit", "Edit Photo", "Edit", Icons.Edit, Adjustments::save, "edit")
                ops += tool("image.annotate", "Annotate", null, Icons.Annotate, AnnotationRenderer::save, "annotate")
            }
            ops += tool("image.frame", "Add Background", "Add BG", Icons.Background, { f, c -> ImageTools.addBackground(f, c) }, "frame")
            ops += tool("image.crop", "Crop", null, Icons.Crop, ImageTools::cropTool, "crop")
            if (single) ops += tool("image.redact", "Redact", null, Icons.Redact, ImageTools::redact, "redact")
            ops += tool("image.rotate", "Rotate", null, Icons.Rotate, ImageTools::rotate)
            ops += tool("image.ocr", "Copy Text", "Text", Icons.Text, ImageTools::extractText)
            ops += tool("image.qr", "Read QR Code", "QR Code", Icons.Qr, ImageTools::readCodes, producesFiles = false)
            if (!single) {
                ops += tool("image.topdf", "Create PDF", "PDF", Icons.Pdf, ImageOps::makePdf)
                ops += tool("image.collage", "Create Collage", "Collage", Icons.Collage, { f, c -> ImageTools.makeCollage(f, c) }, "collage")
            }
        }

        if (kinds == setOf(FileKind.Pdf)) {
            ops += tool("pdf.compress", "Compress", null, Icons.Compress, { f, c -> PdfOps.compress(f, c) }, "compress")
            ops += tool("pdf.metadata", "Remove Metadata", "Metadata", Icons.Metadata, PdfOps::stripMetadata)
            ops += if (single) tool("pdf.organize", "Organize Pages", "Organize", Icons.Organize, PdfOps::organize, "organize")
                   else tool("pdf.merge", "Merge PDFs", "Merge", Icons.Merge, PdfOps::merge, "merge")
            ops += tool("pdf.split", "Split Pages", "Split", Icons.Split, PdfOps::split)
            ops += tool("pdf.ocr", "Copy Text", "Text", Icons.Text, ImageTools::extractText)
        }

        if (kinds == setOf(FileKind.Video)) {
            ops += tool("video.compress", "Compress", null, Icons.Compress, { f, c -> VideoOps.compress(f, c) }, "compress")
            ops += tool("video.metadata", "Remove Metadata", "Metadata", Icons.Metadata, AudioOps::stripMetadata)
            if (single) {
                ops += tool("video.trim", "Trim", null, Icons.Trim, MediaTools::trim, "trim")
                ops += tool("video.crop", "Crop Video", "Crop", Icons.Crop, MediaTools::crop, "crop-video")
                ops += tool("video.speed", "Change Speed", "Speed", Icons.Speed, MediaTools::speed, "speed")
                ops += tool("video.frames", "Save Frames", "Frames", Icons.Camera, MediaTools::frames, "frames")
                ops += tool("video.split", "Split Video", "Split", Icons.Split, MediaTools::split, "split")
                ops += tool("video.redact", "Redact Video", "Redact", Icons.Redact, MediaTools::redact, "redact-video")
            } else {
                ops += tool("video.join", "Join Videos", "Join", Icons.Join, VideoOps::join, "join")
            }
            ops += tool("video.rotate", "Rotate", null, Icons.Rotate, VideoOps::rotate)
            ops += tool("video.mute", "Mute", null, Icons.Mute, VideoOps::mute)
            ops += tool("video.normalize", "Normalize Volume", "Normalize", Icons.Volume, VideoOps::normalize, if (single) "normalize" else null)
        }

        if (kinds == setOf(FileKind.Audio)) {
            ops += tool("audio.compress", "Compress", null, Icons.Compress, { f, c -> AudioOps.compress(f, c) }, "compress")
            ops += tool("audio.metadata", "Remove Metadata", "Metadata", Icons.Metadata, AudioOps::stripMetadata)
            ops += tool("audio.normalize", "Normalize Volume", "Normalize", Icons.Volume, AudioOps::normalize, if (single) "normalize" else null)
            if (single) {
                ops += tool("audio.visualizer", "Audio Visualizer", "Visualizer", Icons.Waveform, Visualizer::make, "visualizer")
                ops += tool("audio.trim", "Trim", null, Icons.Trim, MediaTools::trim, "trim")
                ops += tool("audio.channels", "Convert Channels", "Channels", Icons.Channels, AudioOps::toMono, "channels")
                ops += tool("audio.bleep", "Bleep Audio", "Bleep", Icons.Bleep, MediaTools::bleep, "bleep")
            } else {
                ops += tool("audio.silence", "Trim Silence", "Silence", Icons.Silence, AudioOps::trimSilence)
                ops += tool("audio.mono", "To Mono", "Mono", Icons.Channels, AudioOps::toMono)
            }
        }

        if (kinds == setOf(FileKind.Archive)) ops += tool("archive.extract", "Extract", null, Icons.Extract, ArchiveOps::extract)

        if (QrCode.canEncode(files)) ops += tool("text.qr", "Create QR Code", "Make QR", Icons.Qr, QrCode::quick, "qr")

        return ops
    }

    // Actions

    /** The same actions for any file, clockwise from the top. The app performs them. */
    private fun actions(files: List<File>): List<Operation> = buildList {
        add(tool("action.share", "Share", null, Icons.Share, FileActions.Share, producesFiles = false))
        add(tool("action.open", "Open With", "Open", Icons.OpenWith, FileActions.OpenWith, producesFiles = false))
        add(tool("action.copy", "Copy", null, Icons.Copy, FileActions.Copy, producesFiles = false))
        add(tool("action.save", "Save To", "Save", Icons.Save, FileActions.SaveTo, producesFiles = false))
        if (files.kinds().all { it == FileKind.Image || it == FileKind.Pdf }) {
            add(tool("action.print", "Print", null, Icons.Print, FileActions.Print, producesFiles = false))
        }
        add(tool("action.details", "Details", null, Icons.Info, FileActions.Details, producesFiles = false))
    }
}
