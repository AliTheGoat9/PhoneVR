package com.phonevr.core

/**
 * Turns RTP packets carrying H.265 (RFC 7798, as produced by `ffmpeg -f rtp`) back into Annex-B access units
 * that MediaCodec can decode.
 *
 * Handles the three payload kinds ffmpeg emits: single NAL unit, aggregation packet (type 48, used for the
 * small VPS/SPS/PPS) and fragmentation unit (type 49, used for big slices).
 *
 * Loss policy: an access unit that lost any packet is dropped whole. Until the first keyframe (IRAP) the output
 * is withheld because the decoder needs the in-band parameter sets; with [waitForKeyframeAfterLoss] the same
 * happens after every loss (frozen picture until the next IDR instead of smeared artefacts).
 *
 * Pure Kotlin, no Android classes. Single-threaded: call [push] from one thread. The buffer handed to
 * [onAccessUnit] is only valid during the callback.
 */
class HevcRtpDepacketizer(
    var waitForKeyframeAfterLoss: Boolean = false,
    private val onAccessUnit: (data: ByteArray, size: Int, keyframe: Boolean) -> Unit,
) {
    private var buf = ByteArray(1 shl 20)
    private var size = 0
    private var haveSeq = false
    private var lastSeq = 0
    private var haveTs = false
    private var curTs = 0L
    private var broken = false   // the access unit being assembled lost something
    private var key = false     // ... and contains an IRAP NAL (types 16..23)
    private var needKey = true  // withhold output until a keyframe access unit arrives
    private var fuOpen = false  // inside a fragmented NAL unit

    var packets = 0L; private set
    var accessUnits = 0L; private set
    var droppedAccessUnits = 0L; private set
    var lostPackets = 0L; private set

    fun push(p: ByteArray, len: Int) {
        if (len < 12) return
        val b0 = p[0].toInt() and 0xFF
        if ((b0 shr 6) != 2) return                      // not RTP v2
        val b1 = p[1].toInt() and 0xFF
        if ((b1 and 0x7F) in 64..95) return              // RTCP-range payload types, never video
        val marker = (b1 and 0x80) != 0
        val seq = ((p[2].toInt() and 0xFF) shl 8) or (p[3].toInt() and 0xFF)
        val ts = ((p[4].toLong() and 0xFF) shl 24) or ((p[5].toLong() and 0xFF) shl 16) or
            ((p[6].toLong() and 0xFF) shl 8) or (p[7].toLong() and 0xFF)

        var off = 12 + 4 * (b0 and 0x0F)                 // fixed header + CSRCs
        if ((b0 and 0x10) != 0) {                        // header extension
            if (off + 4 > len) return
            off += 4 + 4 * (((p[off + 2].toInt() and 0xFF) shl 8) or (p[off + 3].toInt() and 0xFF))
        }
        var end = len
        if ((b0 and 0x20) != 0 && len > 0) end -= (p[len - 1].toInt() and 0xFF)   // padding
        if (off + 3 > end) return                        // need at least a 2-byte payload header + 1 byte
        packets++

        var gap = false
        if (haveSeq && seq != ((lastSeq + 1) and 0xFFFF)) {
            gap = true
            lostPackets += ((seq - lastSeq - 1) and 0xFFFF)
        }
        lastSeq = seq
        haveSeq = true

        if (haveTs && ts != curTs && (size > 0 || broken)) {
            // New timestamp but the previous access unit never saw its marker bit: its last packet is gone.
            dropCurrent()
        }
        haveTs = true
        curTs = ts
        if (gap) broken = true

        val type = (p[off].toInt() shr 1) and 0x3F
        when {
            type <= 47 -> {                              // single NAL unit packet
                if (!broken) {
                    startNal(end - off)
                    append(p, off, end - off)
                    noteNal(type)
                }
                fuOpen = false
            }
            type == 48 -> {                              // aggregation packet: [u16 size][NAL]...
                var o = off + 2
                while (o + 2 <= end && !broken) {
                    val n = ((p[o].toInt() and 0xFF) shl 8) or (p[o + 1].toInt() and 0xFF)
                    o += 2
                    if (n < 2 || o + n > end) { broken = true; break }
                    startNal(n)
                    append(p, o, n)
                    noteNal((p[o].toInt() shr 1) and 0x3F)
                    o += n
                }
                fuOpen = false
            }
            type == 49 -> {                              // fragmentation unit
                val fu = p[off + 2].toInt() and 0xFF
                val first = (fu and 0x80) != 0
                val last = (fu and 0x40) != 0
                val fuType = fu and 0x3F
                if (first) {
                    if (!broken) {
                        if (startNal(end - off) && ensure(2)) {
                            buf[size++] = ((p[off].toInt() and 0x81) or (fuType shl 1)).toByte()
                            buf[size++] = p[off + 1]
                            noteNal(fuType)
                        }
                    }
                    fuOpen = true
                } else if (!fuOpen) {
                    broken = true                         // continuation without a start fragment
                }
                if (!broken) append(p, off + 3, end - off - 3)
                if (last) fuOpen = false
            }
            else -> broken = true                         // PACI / unknown: unsupported
        }

        if (marker) finishAccessUnit()
    }

    private fun finishAccessUnit() {
        if (broken) { dropCurrent(); return }
        if (size == 0) return
        if (needKey && !key) { reset(); return }          // still waiting for a decodable start
        needKey = false
        accessUnits++
        onAccessUnit(buf, size, key)
        reset()
    }

    private fun dropCurrent() {
        droppedAccessUnits++
        if (waitForKeyframeAfterLoss) needKey = true
        reset()
    }

    private fun reset() {
        size = 0
        broken = false
        key = false
        fuOpen = false
    }

    private fun noteNal(type: Int) {
        if (type in 16..23) key = true
    }

    private fun startNal(extra: Int): Boolean {
        if (!ensure(4 + extra)) return false
        buf[size++] = 0; buf[size++] = 0; buf[size++] = 0; buf[size++] = 1
        return true
    }

    private fun append(src: ByteArray, from: Int, n: Int) {
        if (n <= 0 || broken) return
        if (!ensure(n)) return
        System.arraycopy(src, from, buf, size, n)
        size += n
    }

    /** Makes room for [extra] more bytes. On failure (absurdly large access unit) marks the unit broken. */
    private fun ensure(extra: Int): Boolean {
        if (size + extra <= buf.size) return true
        if (size + extra > MAX_AU_BYTES) { broken = true; return false }
        var n = buf.size
        while (n < size + extra) n = n shl 1
        buf = buf.copyOf(n)
        return true
    }

    private companion object {
        const val MAX_AU_BYTES = 64 shl 20
    }
}
