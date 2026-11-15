package com.linkmymac.android.service

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import android.util.Size
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * =============================================================================
 * MediaStoreProvider: Camera Roll Indexing & Chunked File Streaming Engine
 * =============================================================================
 * WHAT IT DOES: Interfaces with Android's system `MediaStore` database to query
 *               photo library metadata, generate lightweight 200x200 WebP thumbnails,
 *               and delete items. (Full-resolution downloads stream through
 *               P2PDaemonService.streamFile, shared with file sharing.)
 * HOW IT DOES IT:
 *   1. Performs indexed cursor queries on `MediaStore.Images.Media.EXTERNAL_CONTENT_URI`
 *      sorted descending by modification time.
 *   2. Generates responsive thumbnail previews via `ContentResolver.loadThumbnail()`
 *      compressed into WebP format at 75% quality.
 * WHY IT DOES IT: Empowers macOS users to browse their phone's camera roll with
 *                 instant visual previews and download full-resolution original
 *                 photos over high-throughput Wi-Fi or USB without third-party cloud
 *                 services or compression degradation.
 * =============================================================================
 */
class MediaStoreProvider(private val context: Context) {

    companion object {
        private val FILES_URI: Uri = MediaStore.Files.getContentUri("external")
        // Photos and videos together; MediaStore gives both one shared id space.
        private val MEDIA_SELECTION = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (" +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}, ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO})"
    }

    /** Download/delete only get an id from the Mac: look up whether it's a photo or a video. */
    fun contentUriFor(mediaId: Long): Uri {
        val isVideo = try {
            context.contentResolver.query(
                ContentUris.withAppendedId(FILES_URI, mediaId),
                arrayOf(MediaStore.Files.FileColumns.MEDIA_TYPE), null, null, null
            )?.use { it.moveToFirst() && it.getInt(0) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO } ?: false
        } catch (_: Exception) {
            false
        }
        return contentUriFor(mediaId, isVideo)
    }

    private fun contentUriFor(mediaId: Long, isVideo: Boolean): Uri = ContentUris.withAppendedId(
        if (isVideo) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
        mediaId
    )

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
    /** [mediaType] "image" or "video" pages one kind (the Mac shows them in separate sections); "" pages both. */
    fun queryMediaIndex(offset: Int, limit: Int, includeThumbnails: Boolean, mediaType: String = ""): JSONObject {
        val selection = when (mediaType) {
            "image" -> "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE}"
            "video" -> "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ${MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO}"
            else -> MEDIA_SELECTION
        }
        val itemsArray = JSONArray()
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.WIDTH,
            MediaStore.Files.FileColumns.HEIGHT,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DURATION
        )

        val sortOrder = "${MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        var totalCount = 0

        try {
            context.contentResolver.query(
                FILES_URI,
                projection,
                selection,
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
                    val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                    val durationCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DURATION)

                    var fetched = 0
                    do {
                        val mediaId = cursor.getLong(idCol)
                        val isVideo = cursor.getInt(typeCol) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                        val contentUri = contentUriFor(mediaId, isVideo) // loadThumbnail grabs a frame for videos

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
                            put("mimeType", cursor.getString(mimeCol) ?: if (isVideo) "video/mp4" else "image/jpeg")
                            put("durationMs", if (isVideo) cursor.getLong(durationCol) else 0L)
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
            put("mediaType", mediaType)
            put("offset", offset)
            put("totalCount", totalCount)
            put("items", itemsArray)
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
        val contentUri = contentUriFor(mediaId)

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
            for (uri in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI)) {
                context.contentResolver.registerContentObserver(uri, true, contentObserver!!)
            }
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
