package com.phonevr.core

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Wire format shared with the SteamVR driver. Mirrors driver/src/protocol.h exactly:
 *   phone -> PC  UDP posePort   PosePacket   52 bytes
 *   PC -> phone  UDP configPort ConfigPacket 28 bytes
 * Both little-endian and tightly packed. Pure Kotlin (no Android classes) so it can be unit tested on a JVM.
 */
object Protocol {
    const val POSE_MAGIC = 0x50525650   // bytes "PVRP"
    const val CONFIG_MAGIC = 0x43525650 // bytes "PVRC"
    const val VERSION = 1

    const val FLAG_LANDSCAPE_RIGHT = 1 shl 0 // display rotation is ROTATION_270 (top edge on the user's right)
    const val FLAG_RECENTER = 1 shl 1

    const val POSE_SIZE = 52
    const val CONFIG_SIZE = 28

    const val DEFAULT_VIDEO_PORT = 5000   // RTP / H.265 from ffmpeg
    const val DEFAULT_CONFIG_PORT = 5001  // driver -> phone
    const val DEFAULT_POSE_PORT = 5555    // phone -> driver
}

/** What the driver tells the phone about the image it is producing. */
data class PcConfig(
    val tanHalfX: Float,
    val tanHalfY: Float,
    val eyeWidth: Int,
    val eyeHeight: Int,
    val displayHz: Float,
    val appliedIpdMm: Float,
) {
    /** Size of the whole captured window: both eyes side by side. */
    val videoWidth: Int get() = eyeWidth * 2
    val videoHeight: Int get() = eyeHeight

    companion object {
        /** Returns null for anything that is not a valid ConfigPacket (e.g. ffmpeg's RTCP reports, which land on the same port). */
        fun parse(buf: ByteArray, len: Int): PcConfig? {
            if (len < Protocol.CONFIG_SIZE) return null
            val b = ByteBuffer.wrap(buf, 0, len).order(ByteOrder.LITTLE_ENDIAN)
            if (b.getInt(0) != Protocol.CONFIG_MAGIC) return null
            if ((b.getShort(4).toInt() and 0xFFFF) != Protocol.VERSION) return null
            val tx = b.getFloat(8)
            val ty = b.getFloat(12)
            val ew = b.getShort(16).toInt() and 0xFFFF
            val eh = b.getShort(18).toInt() and 0xFFFF
            val hz = b.getFloat(20)
            val ipd = b.getFloat(24)
            if (!(tx > 0.05f && tx < 20f && ty > 0.05f && ty < 20f)) return null
            if (ew < 64 || eh < 64) return null
            return PcConfig(tx, ty, ew, eh, if (hz in 24f..500f) hz else 60f, ipd)
        }
    }
}

/** Builds PosePackets into a reusable buffer (not thread safe: use one instance per sending thread). */
class PoseWriter {
    private val bytes = ByteArray(Protocol.POSE_SIZE)
    private val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    private var seq = 0

    val buffer: ByteArray get() = bytes

    /**
     * @param q rotation-vector quaternion x, y, z, w (device -> Android ENU world)
     * @param gyro rad/s in the device frame
     * @return packet length (always POSE_SIZE)
     */
    fun write(flags: Int, sensorTimeNs: Long, q: FloatArray, gyro: FloatArray, ipdMm: Float): Int {
        buf.clear()
        buf.putInt(Protocol.POSE_MAGIC)
        buf.putShort(Protocol.VERSION.toShort())
        buf.putShort(flags.toShort())
        buf.putInt(seq++)
        buf.putLong(sensorTimeNs)
        for (i in 0 until 4) buf.putFloat(q[i])
        for (i in 0 until 3) buf.putFloat(gyro[i])
        buf.putFloat(ipdMm)
        return Protocol.POSE_SIZE
    }
}
