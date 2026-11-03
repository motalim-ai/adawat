package com.motalim.adawat.ops

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.graphics.Paint
import com.motalim.adawat.core.AdawatException
import java.io.File

object Images {
    private const val MAX_PIXELS = 50_000_000.0

    /** Decodes any picture Android can read, already turned upright, in software memory so its pixels can be read. */
    fun decode(file: File, maxSide: Int = 0): Bitmap = try {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.isMutableRequired = false
            val side = maxOf(info.size.width, info.size.height)
            // Even at full size, at most 50 MP (200 MB of pixels): a 200 MP photo would otherwise get the app killed.
            val pixels = info.size.width.toDouble() * info.size.height
            val scale = minOf(if (maxSide in 1 until side) maxSide.toDouble() / side else 1.0, Math.sqrt(MAX_PIXELS / pixels))
            if (scale < 1) decoder.setTargetSize((info.size.width * scale).toInt().coerceAtLeast(1), (info.size.height * scale).toInt().coerceAtLeast(1))
        }.let { if (it.config == Bitmap.Config.ARGB_8888) it else it.copy(Bitmap.Config.ARGB_8888, false) }
    } catch (e: Exception) {
        throw AdawatException("Could not read ${file.name}.")
    }

    /** Upright width and height without decoding the pixels. */
    fun size(file: File): Pair<Int, Int> {
        var result = 0 to 0
        try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
                result = info.size.width to info.size.height
                decoder.setTargetSize(1, 1)
            }
        } catch (e: Exception) {
            if (result.first == 0) throw AdawatException("Could not read ${file.name}.")
        }
        return result
    }

    /** The picture on white, for formats without transparency. */
    fun flatten(bitmap: Bitmap): Bitmap {
        if (!bitmap.hasAlpha()) return bitmap
        val result = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
        Canvas(result).apply {
            drawColor(Color.WHITE)
            drawBitmap(bitmap, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
        }
        return result
    }

    fun rotate(bitmap: Bitmap, degrees: Float): Bitmap =
        Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, Matrix().apply { postRotate(degrees) }, true)

    /** Centred on a transparent square no larger than [max]. */
    fun fitSquare(bitmap: Bitmap, max: Int): Bitmap {
        val side = minOf(max, maxOf(bitmap.width, bitmap.height))
        val scale = side.toFloat() / maxOf(bitmap.width, bitmap.height)
        val result = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val w = bitmap.width * scale
        val h = bitmap.height * scale
        Canvas(result).drawBitmap(bitmap, null, android.graphics.RectF((side - w) / 2, (side - h) / 2, (side + w) / 2, (side + h) / 2),
                                  Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return result
    }
}
