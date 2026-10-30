package com.cometchat.push_notifications

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.util.LruCache
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads sender avatars, circle-crops them and keeps the recent ones in
 * memory.
 *
 * Best-effort throughout: a failed download returns null and the notification
 * is posted without a large icon, which is a far better outcome than delaying
 * or dropping it. The cache is memory-only and dies with the process — an
 * avatar is cheap to fetch again, and notifications are not worth a disk cache.
 */
internal object AvatarLoader {

    private const val CACHE_SIZE = 20
    private const val CONNECT_TIMEOUT_MS = 5_000
    private const val READ_TIMEOUT_MS = 5_000
    private const val AVATAR_SIZE_PX = 128
    private const val MAX_DOWNLOAD_BYTES = 2 * 1024 * 1024

    private val cache = LruCache<String, Bitmap>(CACHE_SIZE)

    /**
     * The circle-cropped avatar at [url], or null if it is absent or
     * unreachable. Blocking: call it off the main thread.
     */
    fun load(url: String?): Bitmap? {
        if (url.isNullOrBlank()) return null
        cache.get(url)?.let { return it }

        return try {
            val source = download(url) ?: return null
            val cropped = circleCrop(source)
            cache.put(url, cropped)
            cropped
        } catch (e: Exception) {
            Log.w("Avatar download failed: ${e.message}")
            null
        }
    }

    /**
     * Downloads [url] and decodes it at roughly [AVATAR_SIZE_PX].
     *
     * Decoded in two passes, reading the dimensions first so the pixels are
     * never fully materialized. The URL comes from the push payload and points
     * at whatever the sender uploaded, so a full-resolution decode is an
     * out-of-memory crash waiting for someone with a large avatar — and it
     * would happen in the notification path, taking the app down as a message
     * arrives.
     */
    private fun download(url: String): Bitmap? {
        val bytes = fetch(url) ?: return null

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            Log.w("Avatar was not a decodable image")
            return null
        }

        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
        }
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    }

    /** The smallest power of two that brings the image down to avatar size. */
    private fun sampleSizeFor(width: Int, height: Int): Int {
        var sampleSize = 1
        while (
            width / (sampleSize * 2) >= AVATAR_SIZE_PX &&
            height / (sampleSize * 2) >= AVATAR_SIZE_PX
        ) {
            sampleSize *= 2
        }
        return sampleSize
    }

    private fun fetch(url: String): ByteArray? {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = CONNECT_TIMEOUT_MS
            connection.readTimeout = READ_TIMEOUT_MS
            connection.doInput = true
            connection.connect()
            if (connection.responseCode != HttpURLConnection.HTTP_OK) {
                Log.w("Avatar download returned HTTP ${connection.responseCode}")
                return null
            }
            // Capped, because Content-Length is the server's claim, not a
            // promise, and this buffer is held in memory.
            val length = connection.contentLength
            if (length > MAX_DOWNLOAD_BYTES) {
                Log.w("Avatar is larger than ${MAX_DOWNLOAD_BYTES / 1024}KB — skipped")
                return null
            }
            connection.inputStream.use { it.readAtMost(MAX_DOWNLOAD_BYTES) }
        } finally {
            connection.disconnect()
        }
    }

    /** Reads at most [limit] bytes, or null if the stream runs past it. */
    private fun java.io.InputStream.readAtMost(limit: Int): ByteArray? {
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(8 * 1024)
        while (true) {
            val read = read(chunk)
            if (read == -1) return buffer.toByteArray()
            if (buffer.size() + read > limit) {
                Log.w("Avatar exceeded ${limit / 1024}KB while downloading — skipped")
                return null
            }
            buffer.write(chunk, 0, read)
        }
    }

    private fun circleCrop(source: Bitmap): Bitmap {
        val size = minOf(source.width, source.height, AVATAR_SIZE_PX)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint().apply { isAntiAlias = true }

        val rect = Rect(0, 0, size, size)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)

        val scaled = Bitmap.createScaledBitmap(source, size, size, true)
        canvas.drawBitmap(scaled, rect, rect, paint)
        if (scaled !== source) scaled.recycle()

        return output
    }
}
