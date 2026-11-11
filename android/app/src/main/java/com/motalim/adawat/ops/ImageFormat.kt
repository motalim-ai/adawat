package com.motalim.adawat.ops

import android.media.MediaCodecList
import android.media.MediaFormat
import com.motalim.adawat.core.ext
import java.io.File

class ImageFormat private constructor(val title: String, val ext: String, val lossy: Boolean) {
    /** Whether this phone can write the format. HEIC needs an HEVC encoder, which nearly every phone has. */
    val canWrite: Boolean
        get() = when (this) {
            Heic -> hevcEncoder
            Avif -> false
            else -> true
        }

    override fun toString() = title

    companion object {
        val Png = ImageFormat("PNG", "png", false)
        val Jpeg = ImageFormat("JPEG", "jpg", true)
        val Heic = ImageFormat("HEIC", "heic", true)
        val WebP = ImageFormat("WebP", "webp", true)
        val Avif = ImageFormat("AVIF", "avif", true)
        val Tiff = ImageFormat("TIFF", "tiff", false)
        val Gif = ImageFormat("GIF", "gif", false)
        val Bmp = ImageFormat("BMP", "bmp", false)
        val Ico = ImageFormat("ICO", "ico", false)

        val all = listOf(Png, Jpeg, Heic, WebP, Avif, Tiff, Gif, Bmp, Ico)

        fun of(file: File): ImageFormat? = when (val ext = file.ext) {
            "jpeg", "jfif" -> Jpeg
            "tif" -> Tiff
            "heif" -> Heic
            else -> all.firstOrNull { it.ext == ext }
        }

        /** A phone that will not list its encoders gets a wheel without HEIC, rather than no wheel. */
        private val hevcEncoder by lazy {
            runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info ->
                    info.isEncoder && info.supportedTypes.any {
                        it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, true) || it.equals(MediaFormat.MIMETYPE_IMAGE_ANDROID_HEIC, true)
                    }
                }
            }.getOrDefault(false)
        }
    }
}
