package com.phonevr

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Process
import android.util.Log
import android.view.Surface

/**
 * Hardware H.265 decoder rendering straight into [surface] (the SurfaceTexture the GL renderer samples).
 * Input is fed from the network thread via [queue]; a second thread releases decoded frames to the surface as
 * soon as they come out, which is what keeps latency low.
 */
class VideoDecoder(
    private val surface: Surface,
    val width: Int,
    val height: Int,
    private val hz: Float,
) {
    private var codec: MediaCodec? = null
    private var outThread: Thread? = null
    @Volatile private var running = false
    private var ptsUs = 0L
    private val frameUs = (1_000_000f / hz).toLong().coerceAtLeast(1)

    @Volatile var framesIn = 0L; private set
    @Volatile var framesOut = 0L; private set
    @Volatile var framesDropped = 0L; private set

    fun start(): Boolean {
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setInteger(MediaFormat.KEY_PRIORITY, 0)                       // real-time
                setInteger(MediaFormat.KEY_OPERATING_RATE, hz.toInt().coerceAtLeast(60))
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 4 * 1024 * 1024)
                setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
                setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            }
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_HEVC)
            c.configure(format, surface, null, 0)
            c.start()
            codec = c
            running = true
            outThread = Thread({ drain(c) }, "phonevr-decoder-out").also { it.start() }
            Log.i(TAG, "decoder ${c.name} started ${width}x$height @ ${hz.toInt()} Hz")
            return true
        } catch (e: Exception) {
            Log.e(TAG, "decoder start failed: ${e.message}")
            release()
            return false
        }
    }

    /** Feeds one Annex-B access unit. Returns false if it had to be dropped (decoder backed up). */
    fun queue(data: ByteArray, size: Int): Boolean {
        val c = codec ?: return false
        if (!running) return false
        try {
            val i = c.dequeueInputBuffer(4_000)
            if (i < 0) { framesDropped++; return false }
            val buf = c.getInputBuffer(i)
            if (buf == null || size > buf.capacity()) {
                c.queueInputBuffer(i, 0, 0, ptsUs, 0)
                framesDropped++
                return false
            }
            buf.clear()
            buf.put(data, 0, size)
            c.queueInputBuffer(i, 0, size, ptsUs, 0)
            ptsUs += frameUs
            framesIn++
            return true
        } catch (e: IllegalStateException) {
            Log.w(TAG, "queue: ${e.message}")
            return false
        } catch (e: MediaCodec.CodecException) {
            Log.w(TAG, "queue: ${e.message}")
            return false
        }
    }

    private fun drain(c: MediaCodec) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                val i = c.dequeueOutputBuffer(info, 8_000)
                if (i >= 0) {
                    c.releaseOutputBuffer(i, true)   // render immediately
                    framesOut++
                }
            } catch (e: IllegalStateException) {
                if (running) Log.w(TAG, "drain: ${e.message}")
                break
            } catch (e: MediaCodec.CodecException) {
                Log.w(TAG, "drain: ${e.message}")
            }
        }
    }

    fun stop() {
        running = false
        try { outThread?.join(500) } catch (_: InterruptedException) { }
        outThread = null
        release()
    }

    private fun release() {
        val c = codec ?: return
        codec = null
        try { c.stop() } catch (_: Exception) { }
        try { c.release() } catch (_: Exception) { }
    }

    private companion object { const val TAG = "PhoneVR" }
}
