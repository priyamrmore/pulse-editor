package com.margelo.nitro.pulseeditor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.inspector.frame.FrameExtractor
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.pulseeditor.merge.Merge
import com.margelo.nitro.pulseeditor.merge.MergeException
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * One frame as a JPEG: Media3's `FrameExtractor` (an exact seek, decoded on the platform decoder,
 * HDR tone-mapped to SDR), then the clip's edit drawn on the bitmap with merge's own geometry
 * (rotate → flip → crop, as `MergeExport.editEffects`), so an edited clip's cover is drawn as the
 * export renders it. Media3 turns the frame upright itself but leaves a mirrored source's flip to
 * us (as in conform). The picture is scaled to fit the maximum size, never up.
 *
 * The extractor is kept warm for the last source: Media3's extractors share one player, which
 * prepares again whenever the media item changes (160–600 ms per cover on a Galaxy S24 when every
 * call built and closed one), so covers of the same clip — a cover picker, a strip — pay a seek
 * instead. Its effects don't depend on the edit (only the mirror flip and a size bound), which is
 * what lets the same instance serve every edit; a warm extractor whose effects changed per call
 * returned the previous request's frame. The item's id carries the file's size and modification
 * time (a file rewritten at the same path is a new item, so the player can't serve the old file's
 * frame) and the effects (the shared player only prepares again for a new item; with the same one
 * it seeks, and a seek to a frame it just extracted returns that frame, at the old effects).
 */
@OptIn(UnstableApi::class)
internal object FrameGrab {
  /** Frames are extracted no larger than this on the longer side, before the edit: bounded memory and
   * time per cover. A larger `maxWidth`/`maxHeight`, or a tight crop of a 4K source, comes out smaller
   * than asked on Android (Pulse's covers are 192×256). */
  private const val MAX_FRAME_SIDE = 1920
  /** How long the last source's extractor is kept after a cover. */
  private const val WARM_MS = 4000L
  /** `frames` stops after this many failures in a row: the file won't decode, and each try
   * costs a seek. */
  private const val MAX_FAILURES_IN_A_ROW = 3

  private class Warm(val key: String, val extractor: FrameExtractor)

  // Main thread only (FrameExtractor runs its player there).
  private var warm: Warm? = null
  private val main = Handler(Looper.getMainLooper())
  private val release = Runnable { closeWarm() }

  /** Covers run one at a time: `warm` is read and replaced across the frame's await. */
  private val oneAtATime = Mutex()

  suspend fun run(context: Context, uri: String, options: ThumbnailOptions): Thumbnail = oneAtATime.withLock {
    Merge.removeStaleOutputs(context)
    val (bitmap, presentationMs) = grab(context, uri, options)
    val file = Merge.outputFile(context, "frame", "jpg")
    withContext(Dispatchers.IO) {
      file.parentFile?.mkdirs()
      val quality = (options.quality.coerceIn(0.0, 1.0) * 100).roundToInt()
      file.outputStream().use { out ->
        if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) {
          throw MergeException("Couldn't write the image file.")
        }
      }
    }
    Thumbnail(
      uri = Uri.fromFile(file).toString(),
      width = bitmap.width.toDouble(),
      height = bitmap.height.toDouble(),
      timeMs = presentationMs,
    )
  }

  /**
   * Several frames as JPEG bytes, in the order asked: the file's own pictures, upright and
   * unedited, from the warm extractor (taken in source order, so its seeks run forward), the file
   * probed once. Within `toleranceMs` the player takes the nearest keyframe (seek parameters)
   * instead of decoding up to the exact frame. A time that can't be decoded is left out and the rest
   * still come, until [MAX_FAILURES_IN_A_ROW] fail in a row; rejects if no frame decoded.
   */
  suspend fun frames(context: Context, uri: String, options: FramesOptions): Array<Frame> = oneAtATime.withLock {
    val source = Probe.read(context, uri)
    if (source.video == null) throw MergeException("The file has no video.")
    val order = options.timesMs.indices.sortedBy { options.timesMs[it] }
    val out = arrayOfNulls<Frame>(options.timesMs.size)
    val quality = (options.quality.coerceIn(0.0, 1.0) * 100).roundToInt()
    val toleranceMs = max(0.0, options.toleranceMs)
    var failures = 0
    var lastError: Exception? = null
    for (i in order) {
      if (failures >= MAX_FAILURES_IN_A_ROW) break
      val one = ThumbnailOptions(
        options.timesMs[i], options.maxWidth, options.maxHeight, options.quality, 0.0, false, null)
      try {
        val (bitmap, presentationMs) = grab(context, uri, one, source, toleranceMs)
        val bytes = withContext(Dispatchers.Default) {
          java.io.ByteArrayOutputStream().use { buf ->
            if (!bitmap.compress(Bitmap.CompressFormat.JPEG, quality, buf)) {
              throw MergeException("Couldn't encode the frame.")
            }
            buf.toByteArray()
          }
        }
        out[i] = Frame(
          options.timesMs[i], presentationMs, bitmap.width.toDouble(), bitmap.height.toDouble(),
          ArrayBuffer.copy(bytes))
        failures = 0
      } catch (e: CancellationException) {
        throw e
      } catch (e: Exception) {
        // Left out: the caller keeps its nearest frame.
        failures++
        lastError = e
      }
    }
    val got = out.filterNotNull()
    if (got.isEmpty() && lastError != null) {
      throw MergeException("Couldn't decode any frame of the file: ${lastError.message}")
    }
    got.toTypedArray()
  }

  /** The frame at `options.timeMs`, with the edit drawn, and when it starts (ms). Callers hold
   * `oneAtATime`. A filmstrip passes its probe (`source`), and its frames are extracted at the
   * size asked (unedited, nothing to crop) rather than at [MAX_FRAME_SIDE], within `toleranceMs`
   * (0: the exact frame). */
  private suspend fun grab(
    context: Context,
    uri: String,
    options: ThumbnailOptions,
    source: ProbeResult? = null,
    toleranceMs: Double = 0.0,
  ): Pair<Bitmap, Double> {
    val probed = source ?: Probe.read(context, uri)
    val video = probed.video ?: throw MergeException("The file has no video.")

    // Inside the video: a time past its last frame takes the last frame.
    val frameMs = if (video.fps > 0) 1000 / video.fps else 1000 / 30.0
    val lengthMs = if (video.durationMs > 0) video.durationMs else probed.durationMs
    val timeMs = min(max(0.0, options.timeMs), max(0.0, lengthMs - frameMs)).roundToLong()

    val (boundW, boundH) = boundedSize(video).let { (w, h) ->
      if (source != null) fitted(w.toDouble(), h.toDouble(), options.maxWidth, options.maxHeight) else w to h
    }
    // The item: the file as it is now, with the effects (see the class comment). The extractor:
    // that item, at these seek parameters.
    val itemId = "$uri|${fileStamp(uri)}|${video.mirrored}|${boundW}x$boundH"
    val toleranceUs = (toleranceMs * 1000).roundToLong()
    val key = "$itemId|$toleranceUs"
    val frame = withContext(Dispatchers.Main) {
      main.removeCallbacks(release)
      val w = warm?.takeIf { it.key == key } ?: run {
        closeWarm()
        val effects = mutableListOf<Effect>()
        if (video.mirrored) effects += ScaleAndRotateTransformation.Builder().setScale(-1f, 1f).build()
        effects += Presentation.createForWidthAndHeight(boundW, boundH, Presentation.LAYOUT_SCALE_TO_FIT)
        val item = MediaItem.Builder().setUri(mediaUri(uri)).setMediaId(itemId).build()
        val seek = if (toleranceUs > 0) SeekParameters(toleranceUs, toleranceUs) else SeekParameters.EXACT
        Warm(key, FrameExtractor.Builder(context, item).setEffects(effects).setSeekParameters(seek).build())
          .also { warm = it }
      }
      try {
        w.extractor.getFrame(timeMs).await()
      } catch (e: Throwable) {
        closeWarm()
        throw e
      } finally {
        if (warm != null) main.postDelayed(release, WARM_MS)
      }
    }

    val bitmap = withContext(Dispatchers.Default) { edited(frame.bitmap, options) }
    return bitmap to frame.presentationTimeMs.toDouble()
  }

  /** A local file's size and modification time (empty for other URIs). */
  private fun fileStamp(uri: String): String {
    val path = mediaUri(uri).takeIf { it.scheme == null || it.scheme == "file" }?.path ?: return ""
    val file = java.io.File(path)
    return if (file.exists()) "${file.length()}|${file.lastModified()}" else ""
  }

  /** Drops the warm extractor (main thread). */
  fun closeWarm() {
    warm?.extractor?.close()
    warm = null
  }

  /** The upright frame (rotate → flip → crop), fitted into the maximum, never scaled up. */
  private fun edited(upright: Bitmap, options: ThumbnailOptions): Bitmap {
    val degrees = ((options.rotation.roundToInt() % 360) + 360) % 360
    val turned = if (degrees == 0 && !options.flipped) upright else {
      val m = Matrix()
      if (degrees != 0) m.postRotate(degrees.toFloat())
      if (options.flipped) m.postScale(-1f, 1f)
      Bitmap.createBitmap(upright, 0, 0, upright.width, upright.height, m, true)
    }
    val c = options.crop
    val x = ((c?.x ?: 0.0) * turned.width).roundToInt().coerceIn(0, turned.width - 1)
    val y = ((c?.y ?: 0.0) * turned.height).roundToInt().coerceIn(0, turned.height - 1)
    val w = ((c?.w ?: 1.0) * turned.width).roundToInt().coerceIn(1, turned.width - x)
    val h = ((c?.h ?: 1.0) * turned.height).roundToInt().coerceIn(1, turned.height - y)
    val (outW, outH) = fitted(w.toDouble(), h.toDouble(), options.maxWidth, options.maxHeight)
    if (x == 0 && y == 0 && w == turned.width && h == turned.height && outW == w && outH == h) return turned
    val scale = Matrix().apply { postScale(outW / w.toFloat(), outH / h.toFloat()) }
    return Bitmap.createBitmap(turned, x, y, w, h, scale, true)
  }

  /** The source's upright size, scaled down (never up) so its longer side is at most [MAX_FRAME_SIDE]. */
  private fun boundedSize(video: ProbeVideo): Pair<Int, Int> {
    val upright = video.rotation.roundToInt() % 180 != 0
    val w = if (upright) video.height else video.width
    val h = if (upright) video.width else video.height
    val scale = min(1.0, MAX_FRAME_SIDE / max(w, h))
    return max(1, (w * scale).roundToInt()) to max(1, (h * scale).roundToInt())
  }

  /** `w`×`h` scaled down (never up) to fit inside maxWidth × maxHeight; 0 means no limit. */
  private fun fitted(w: Double, h: Double, maxWidth: Double, maxHeight: Double): Pair<Int, Int> {
    var scale = 1.0
    if (maxWidth > 0) scale = min(scale, maxWidth / w)
    if (maxHeight > 0) scale = min(scale, maxHeight / h)
    return max(1, (w * scale).roundToInt()) to max(1, (h * scale).roundToInt())
  }
}
