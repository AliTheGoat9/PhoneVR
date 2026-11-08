package com.phonevr

import android.os.Process
import android.util.Log
import com.phonevr.core.HevcRtpDepacketizer
import com.phonevr.core.PcConfig
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The three UDP conversations with the PC:
 *  - poses out      phone -> driver  (connected socket, one packet per sensor sample)
 *  - config in      driver -> phone  (tiny packet once a second)
 *  - video in       ffmpeg -> phone  (RTP / H.265, reassembled into access units)
 */
class StreamLink(
    private val pcIp: String,
    private val posePort: Int,
    private val configPort: Int,
    private val videoPort: Int,
    waitForKeyframeAfterLoss: Boolean,
) {
    @Volatile var onConfig: ((PcConfig) -> Unit)? = null
    @Volatile var onAccessUnit: ((data: ByteArray, size: Int, keyframe: Boolean) -> Unit)? = null

    private val running = AtomicBoolean(false)
    private var poseSocket: DatagramSocket? = null
    private var configSocket: DatagramSocket? = null
    private var videoSocket: DatagramSocket? = null
    private var threads = emptyList<Thread>()

    private val depacketizer = HevcRtpDepacketizer(waitForKeyframeAfterLoss) { data, size, key ->
        onAccessUnit?.invoke(data, size, key)
    }

    /** Opens the sockets and starts the receive threads. Blocking (may resolve a host name): call off the main thread. Returns an error text or null. */
    fun start(): String? {
        try {
            val pc = InetAddress.getByName(pcIp.trim())
            poseSocket = DatagramSocket().apply { connect(pc, posePort) }
            configSocket = bound(configPort, 64 * 1024)
            videoSocket = bound(videoPort, 8 * 1024 * 1024)
        } catch (e: Exception) {
            close()
            return "Network setup failed: ${e.message}"
        }
        running.set(true)
        threads = listOf(
            loop("phonevr-video", videoSocket!!, 2048) { buf, len -> depacketizer.push(buf, len) },
            loop("phonevr-config", configSocket!!, 512) { buf, len -> PcConfig.parse(buf, len)?.let { onConfig?.invoke(it) } },
            Thread({ statsLoop() }, "phonevr-stats").also { it.isDaemon = true; it.start() },
        )
        return null
    }

    /** Called from the sensor thread. */
    fun sendPose(buf: ByteArray, len: Int) {
        val s = poseSocket ?: return
        try {
            s.send(DatagramPacket(buf, len))
        } catch (_: IOException) {
            // PC unreachable or ICMP port-unreachable from an earlier packet: keep trying, the user may start SteamVR later.
        }
    }

    fun stop() {
        running.set(false)
        close()
        for (t in threads) {
            try { t.join(500) } catch (_: InterruptedException) { }
        }
        threads = emptyList()
    }

    private fun bound(port: Int, rcvBuf: Int): DatagramSocket =
        DatagramSocket(null).apply {
            reuseAddress = true
            receiveBufferSize = rcvBuf
            soTimeout = 250
            bind(InetSocketAddress(port))
        }

    private fun loop(name: String, sock: DatagramSocket, size: Int, handle: (ByteArray, Int) -> Unit): Thread =
        Thread({
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
            val buf = ByteArray(size)
            val dp = DatagramPacket(buf, buf.size)
            while (running.get()) {
                try {
                    dp.length = buf.size
                    sock.receive(dp)
                    handle(buf, dp.length)
                } catch (_: SocketTimeoutException) {
                } catch (e: SocketException) {
                    if (running.get()) Log.w(TAG, "$name: ${e.message}")
                    break
                } catch (e: IOException) {
                    Log.w(TAG, "$name: ${e.message}")
                }
            }
        }, name).also { it.start() }

    private fun statsLoop() {
        var lastPackets = 0L
        while (running.get()) {
            try { Thread.sleep(5000) } catch (_: InterruptedException) { return }
            val d = depacketizer
            Log.i(TAG, "video: ${(d.packets - lastPackets) / 5} pkt/s, ${d.accessUnits} AUs, dropped ${d.droppedAccessUnits}, lost packets ${d.lostPackets}")
            lastPackets = d.packets
        }
    }

    private fun close() {
        for (s in listOf(poseSocket, configSocket, videoSocket)) {
            try { s?.close() } catch (_: Exception) { }
        }
    }

    private companion object { const val TAG = "PhoneVR" }
}
