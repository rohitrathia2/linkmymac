package com.linkmymac.android.service

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.zip.CRC32

/**
 * =============================================================================
 * MediaStoreProvider: Camera Roll Indexing & Chunked File Streaming Engine
 * =============================================================================
 * WHAT IT DOES: Interfaces with Android's system `MediaStore` database to query
 *               photo library metadata, generate lightweight 200x200 WebP thumbnails,
 *               and stream full-resolution media files in 64 KB verified chunks.
 * HOW IT DOES IT:
 *   1. Performs indexed cursor queries on `MediaStore.Images.Media.EXTERNAL_CONTENT_URI`
 *      sorted descending by modification time.
 *   2. Generates responsive thumbnail previews via `ContentResolver.loadThumbnail()`
 *      compressed into WebP format at 75% quality.
 *   3. Reads file binary streams via content URIs, divides bytes into 64 KB slices,
 *      computes a 32-bit CRC32 checksum per block, and dispatches frames over TCP.
 * WHY IT DOES IT: Empowers macOS users to browse their phone's camera roll with
 *                 instant visual previews and download full-resolution original
 *                 photos over high-throughput Wi-Fi or USB without third-party cloud
 *                 services or compression degradation.
 * =============================================================================
 */
class MediaStoreProvider(private val context: Context) {

    companion object {
        /** 64 KB transmission chunk size matching TCP window and memory buffer sweet spots */
        const val CHUNK_SIZE_BYTES = 64 * 1024
    }

    /**
     * -------------------------------------------------------------------------
     * queryMediaIndex: Paginated Photo Catalog Metadata Query
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Queries Android's MediaStore for a paginated slice of camera
     *               roll photos, optionally embedding WebP base64 thumbnails.
     * HOW IT DOES IT:
     *   1. Queries `MediaStore.Images.Media.EXTERNAL_CONTENT_URI` with projection:
     *      `[_ID, DISPLAY_NAME, MIME_TYPE, DATE_MODIFIED, SIZE, WIDTH, HEIGHT]`.
     *   2. Orders results descending by `DATE_MODIFIED` to surface newest photos first.
     *   3. Seeks cursor to `offset` and iterates up to `limit` entries.
     *   4. If `includeThumbnails` is true, calls `loadThumbnail(Size(200, 200))` and
     *      encodes the resulting bitmap into WebP base64.
     *   5. Packages metadata into a `MEDIA_INDEX_RESPONSE` JSON packet.
     * WHY IT DOES IT: Provides fast, smooth pagination for the desktop gallery grid
     *                 without exhausting phone memory or stalling the network socket.
     * -------------------------------------------------------------------------
     */
    fun queryMediaIndex(offset: Int, limit: Int, includeThumbnails: Boolean): JSONObject {
        val itemsArray = JSONArray()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.MIME_TYPE,
            MediaStore.Images.Media.DATE_MODIFIED,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT
        )

        val sortOrder = "${MediaStore.Images.Media.DATE_MODIFIED} DESC"
        var totalCount = 0

        try {
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                sortOrder
            )?.use { cursor ->
                totalCount = cursor.count
                Log.d("MediaStoreProvider", "queryMediaIndex: cursor.count = $totalCount, offset = $offset")
                if (cursor.moveToPosition(offset)) {
                    val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
                    val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
                    val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.MIME_TYPE)
                    val dateCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
                    val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
                    val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
                    val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)

                    var fetched = 0
                    do {
                        val mediaId = cursor.getLong(idCol)
                        val contentUri = ContentUris.withAppendedId(
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                            mediaId
                        )

                        var thumbBase64 = ""
                        if (includeThumbnails) {
                            try {
                                val bmp = context.contentResolver.loadThumbnail(
                                    contentUri,
                                    Size(200, 200),
                                    null
                                )
                                val out = ByteArrayOutputStream()
                                @Suppress("DEPRECATION")
                                bmp.compress(Bitmap.CompressFormat.WEBP, 75, out)
                                thumbBase64 = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
                            } catch (_: Exception) {}
                        }

                        itemsArray.put(JSONObject().apply {
                            put("mediaId", mediaId.toString())
                            put("displayName", cursor.getString(nameCol) ?: "Photo_$mediaId.jpg")
                            put("mimeType", cursor.getString(mimeCol) ?: "image/jpeg")
                            put("dateModifiedSec", cursor.getLong(dateCol))
                            put("sizeBytes", cursor.getLong(sizeCol))
                            put("width", cursor.getInt(widthCol))
                            put("height", cursor.getInt(heightCol))
                            put("thumbnailWebpBase64", thumbBase64)
                        })

                        fetched++
                    } while (cursor.moveToNext() && fetched < limit)
                }
            } ?: run {
                Log.w("MediaStoreProvider", "queryMediaIndex: contentResolver.query returned NULL!")
            }
        } catch (e: Exception) {
            Log.e("MediaStoreProvider", "queryMediaIndex exception", e)
        }

        return JSONObject().apply {
            put("type", "MEDIA_INDEX_RESPONSE")
            put("offset", offset)
            put("totalCount", totalCount)
            put("items", itemsArray)
        }
    }

    /**
     * -------------------------------------------------------------------------
     * streamMediaFileInChunks: High-Speed Chunked Binary Media Streamer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Streams an entire full-resolution original media file to the Mac
     *               in sequential, checksum-verified 64 KB chunks.
     * HOW IT DOES IT:
     *   1. Resolves `contentUri` from `mediaId` and opens an `InputStream`.
     *   2. Allocates a 64 KB buffer and reads sequentially until EOF.
     *   3. Computes a 32-bit CRC32 checksum for each read slice to guard against
     *      network packet corruption.
     *   4. Encodes binary bytes in Base64 and emits a `FILE_CHUNK` JSON frame via
     *      the `onChunk` callback:
     *      `{ type: "FILE_CHUNK", transferId, chunkIndex, dataBase64, crc32 }`.
     *   5. Emits a terminal `FILE_TRANSFER_COMPLETE` frame upon EOF.
     * WHY IT DOES IT: Chunked streaming ensures multi-gigabyte videos or raw photos
     *                 can be transferred smoothly without OutOfMemory errors while
     *                 allowing real-time progress indicators on the desktop.
     * -------------------------------------------------------------------------
     */
    fun streamMediaFileInChunks(
        mediaId: Long,
        transferId: String,
        onChunk: (JSONObject) -> Unit
    ) {
        val contentUri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            mediaId
        )

        val inputStream: InputStream = context.contentResolver.openInputStream(contentUri) ?: return
        inputStream.use { stream ->
            val buffer = ByteArray(CHUNK_SIZE_BYTES)
            var chunkIndex = 0
            var bytesRead: Int
            while (stream.read(buffer).also { bytesRead = it } != -1) {
                val slice = if (bytesRead == CHUNK_SIZE_BYTES) buffer else buffer.copyOf(bytesRead)
                val crc = CRC32().apply { update(slice) }.value

                val chunkFrame = JSONObject().apply {
                    put("type", "FILE_CHUNK")
                    put("transferId", transferId)
                    put("chunkIndex", chunkIndex)
                    put("dataBase64", Base64.encodeToString(slice, Base64.NO_WRAP))
                    put("crc32", crc)
                }
                onChunk(chunkFrame)
                chunkIndex++
            }

            onChunk(JSONObject().apply {
                put("type", "FILE_TRANSFER_COMPLETE")
                put("transferId", transferId)
                put("totalChunks", chunkIndex)
                put("verified", true)
            })
        }
    }

    /**
     * -------------------------------------------------------------------------
     * deleteMediaItem: Remote Media Item Deletion Handler
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Permanently deletes a photo from Android MediaStore and storage.
     * HOW IT DOES IT:
     *   1. Resolves content URI via ContentUris.withAppendedId.
     *   2. Attempts ContentResolver.delete() on the MediaStore URI.
     *   3. Queries DATA path column as fallback to delete physical file if needed.
     * WHY IT DOES IT: Allows macOS users to organize and prune their phone gallery
     *                 directly from the desktop application.
     * -------------------------------------------------------------------------
     */
    fun deleteMediaItem(mediaId: Long): Boolean {
        val contentUri = ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            mediaId
        )

        // Find file path for fallback
        var filePath: String? = null
        try {
            context.contentResolver.query(
                contentUri,
                arrayOf(MediaStore.Images.Media.DATA),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val dataIdx = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
                    if (dataIdx >= 0) {
                        filePath = cursor.getString(dataIdx)
                    }
                }
            }
        } catch (_: Exception) {}

        // Attempt 1: ContentResolver delete
        try {
            val rows = context.contentResolver.delete(contentUri, null, null)
            if (rows > 0) return true
        } catch (_: Exception) {}

        // Attempt 2: Direct file deletion if MANAGE_EXTERNAL_STORAGE is active
        if (!filePath.isNullOrEmpty()) {
            try {
                val file = File(filePath)
                if (file.exists() && file.delete()) {
                    return true
                }
            } catch (_: Exception) {}
        }

        return false
    }

    private var contentObserver: android.database.ContentObserver? = null

    /**
     * -------------------------------------------------------------------------
     * startObserving: Dynamic Real-time MediaStore Content Observer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Listens for photo additions, deletions, or edits in Android MediaStore.
     * HOW IT DOES IT: Registers a ContentObserver on MediaStore.Images.Media.EXTERNAL_CONTENT_URI.
     * WHY IT DOES IT: Enables automatic dynamic photo sync between Android and Mac without
     *                 manual refresh button clicks.
     * -------------------------------------------------------------------------
     */
    fun startObserving(onChange: () -> Unit) {
        if (contentObserver != null) return
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        contentObserver = object : android.database.ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                super.onChange(selfChange)
                onChange()
            }
        }
        try {
            context.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                contentObserver!!
            )
        } catch (e: Exception) {
            Log.e("MediaStoreProvider", "Failed to register MediaStore content observer", e)
        }
    }

    fun stopObserving() {
        contentObserver?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (_: Exception) {}
            contentObserver = null
        }
    }
}
