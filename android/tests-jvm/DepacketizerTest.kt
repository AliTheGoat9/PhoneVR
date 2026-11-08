// JVM-only tests for the pure-Kotlin core (no Android needed). Run with run_tests.sh.
//
//   rtp-ok    real `ffmpeg -f rtp` HEVC stream  -> depacketizer -> byte-identical NAL units vs the raw .hevc ffmpeg wrote
//   rtp-loss  same stream with packets dropped  -> every emitted access unit is intact; recovery only at keyframes
//   proto     PosePacket -> C++ UdpLink (driver/tests/test_link), ConfigPacket <- C++ driver code
import com.phonevr.core.HevcRtpDepacketizer
import com.phonevr.core.PcConfig
import com.phonevr.core.PoseWriter
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import kotlin.system.exitProcess

private var failures = 0
private fun check(ok: Boolean, msg: String) {
    println((if (ok) "  ok   " else "  FAIL ") + msg)
    if (!ok) failures++
}

private fun splitNals(d: ByteArray): List<ByteArray> {
    val starts = ArrayList<Int>()
    var i = 0
    while (i + 2 < d.size) {
        if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 && d[i + 2].toInt() == 1) { starts.add(i + 3); i += 3 } else i++
    }
    val out = ArrayList<ByteArray>()
    for ((k, s) in starts.withIndex()) {
        var e = if (k + 1 < starts.size) starts[k + 1] - 3 else d.size
        while (e > s && d[e - 1].toInt() == 0) e--   // zero_byte of a 4-byte start code / trailing zeros
        out.add(d.copyOfRange(s, e))
    }
    return out
}

private class Collected(val nals: List<List<ByteArray>>, val keys: List<Boolean>, val droppedBefore: List<Long>)

/** Runs ffmpeg (HEVC over RTP + raw reference file via tee), feeds every UDP packet to the depacketizer. */
private fun runStream(ffmpeg: String, work: File, dropEvery: Int, waitKey: Boolean): Triple<Collected, List<ByteArray>, HevcRtpDepacketizer> {
    work.mkdirs()
    val ref = File(work, "ref.hevc").also { it.delete() }
    val sock = DatagramSocket(null)
    sock.reuseAddress = true
    sock.receiveBufferSize = 32 shl 20
    sock.bind(InetSocketAddress("127.0.0.1", 5000))
    sock.soTimeout = 400

    val aus = ArrayList<List<ByteArray>>()
    val keys = ArrayList<Boolean>()
    val droppedBefore = ArrayList<Long>()
    lateinit var dep: HevcRtpDepacketizer
    dep = HevcRtpDepacketizer(waitKey) { data, size, key ->
        aus.add(splitNals(data.copyOf(size)))
        keys.add(key)
        droppedBefore.add(dep.droppedAccessUnits)
    }

    val cmd = listOf(
        ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-re",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=60", "-t", "4",
        "-c:v", "libx265", "-preset", "ultrafast", "-tune", "zerolatency",
        "-x265-params", "keyint=30:bframes=0:log-level=error",
        "-bsf:v", "dump_extra=freq=keyframe", "-map", "0:v", "-f", "tee",
        "[f=rtp:payload_type=96]rtp://127.0.0.1:5000?pkt_size=1200|[f=hevc]${ref.absolutePath}",
    )
    val proc = ProcessBuilder(cmd).redirectErrorStream(true).start()
    val sizes = ArrayList<Int>()
    val buf = ByteArray(2048)
    var n = 0
    var idleAfterExit = 0
    while (idleAfterExit < 2) {
        try {
            val dp = DatagramPacket(buf, buf.size)
            sock.receive(dp)
            idleAfterExit = 0
            n++
            if (dropEvery > 0 && n % dropEvery == 17) continue
            sizes.add(dp.length)
            dep.push(buf, dp.length)
        } catch (e: java.net.SocketTimeoutException) {
            if (!proc.isAlive) idleAfterExit++
        }
    }
    val log = proc.inputStream.readBytes().decodeToString().trim()
    if (log.isNotEmpty()) println("  ffmpeg: $log")
    sock.close()
    val refNals = splitNals(ref.readBytes())
    println("  packets sent=$n delivered=${dep.packets} accessUnits=${dep.accessUnits} dropped=${dep.droppedAccessUnits} " +
        "lostPackets=${dep.lostPackets} refNals=${refNals.size}")
    return Triple(Collected(aus, keys, droppedBefore), refNals, dep)
}

private fun nalEq(a: ByteArray, b: ByteArray) = a.contentEquals(b)

private fun testRtpOk(ffmpeg: String, work: File) {
    println("rtp-ok: real ffmpeg RTP/HEVC, no loss")
    val (c, ref, dep) = runStream(ffmpeg, work, 0, false)
    val flat = c.nals.flatten()
    check(dep.lostPackets == 0L, "no packets lost on loopback")
    check(c.nals.size >= 200, "got ${c.nals.size} access units (expect ~240)")
    check(flat.size == ref.size, "NAL count ${flat.size} == reference ${ref.size}")
    check(flat.size == ref.size && flat.indices.all { nalEq(flat[it], ref[it]) }, "every NAL byte-identical to ffmpeg's raw output")
    val types = flat.map { (it[0].toInt() shr 1) and 0x3F }.toSet()
    check(types.containsAll(listOf(32, 33, 34)), "VPS/SPS/PPS present (NAL types seen: ${types.sorted()})")
    check(c.keys.firstOrNull() == true, "first emitted access unit is a keyframe")
    check(c.keys.count { it } in 6..10, "keyframes: ${c.keys.count { it }} (keyint=30 over 4 s)")
}

private fun testRtpLoss(ffmpeg: String, work: File) {
    println("rtp-loss: every 53rd packet dropped, waitForKeyframeAfterLoss=true")
    val (c, ref, dep) = runStream(ffmpeg, work, 53, true)
    check(dep.droppedAccessUnits > 0, "some access units were dropped (${dep.droppedAccessUnits})")
    check(c.nals.isNotEmpty(), "still decodable output (${c.nals.size} access units)")
    // each emitted AU must appear intact, in order, in the reference
    var pos = 0
    var intact = 0
    for (au in c.nals) {
        var found = -1
        var s = pos
        while (s + au.size <= ref.size) {
            if (au.indices.all { nalEq(au[it], ref[s + it]) }) { found = s; break }
            s++
        }
        if (found >= 0) { intact++; pos = found + au.size }
    }
    check(intact == c.nals.size, "all ${c.nals.size} emitted access units are intact and in order (found $intact)")
    var resyncOk = true
    for (i in c.nals.indices) {
        val prev = if (i == 0) 0L else c.droppedBefore[i - 1]
        if (c.droppedBefore[i] > prev && !c.keys[i]) resyncOk = false
    }
    check(resyncOk, "after every loss the next emitted access unit is a keyframe")
}

private fun testProto() {
    println("proto: Kotlin <-> C++ driver structs")
    val cfgSock = DatagramSocket(null).also { it.reuseAddress = true; it.bind(InetSocketAddress("127.0.0.1", 15001)); it.soTimeout = 4000 }
    val tx = DatagramSocket()
    val w = PoseWriter()
    val q = floatArrayOf(0f, 0.258819f, 0f, 0.965926f)
    val gyro = floatArrayOf(0.1f, 0.2f, 0.3f)
    for (flags in intArrayOf(0, 1, 2)) {
        val n = w.write(flags, 123456790L + flags, q, gyro, 63.5f)
        tx.send(DatagramPacket(w.buffer, n, InetAddress.getByName("127.0.0.1"), 15555))
        Thread.sleep(10)
    }
    check(w.buffer.size == 52, "pose packet is 52 bytes")
    val b = ByteArray(256)
    val dp = DatagramPacket(b, b.size)
    cfgSock.receive(dp)
    val cfg = PcConfig.parse(b, dp.length)
    println("  received: $cfg")
    check(cfg != null, "ConfigPacket from C++ UdpLink parses")
    if (cfg != null) {
        check(Math.abs(cfg.tanHalfX - 1.19f) < 1e-4 && Math.abs(cfg.tanHalfY - 1.07f) < 1e-4, "tan half-FOV 1.19 / 1.07")
        check(cfg.eyeWidth == 1496 && cfg.eyeHeight == 1344 && cfg.videoWidth == 2992, "eye 1496x1344, video 2992x1344")
        check(cfg.displayHz == 120f && Math.abs(cfg.appliedIpdMm - 63.5f) < 1e-4, "120 Hz, IPD 63.5")
    }
    val rtcp = ByteArray(28).also { it[0] = 0x80.toByte(); it[1] = 200.toByte() }   // size of an RTCP sender report
    check(PcConfig.parse(rtcp, rtcp.size) == null, "28-byte RTCP report is rejected")
    check(PcConfig.parse(ByteArray(3), 3) == null, "runt packet is rejected")
}

fun main(args: Array<String>) {
    val mode = args[0]
    val ffmpeg = args.getOrElse(1) { "ffmpeg" }
    val work = File(args.getOrElse(2) { "/tmp/phonevr-jvm-test" })
    when (mode) {
        "rtp-ok" -> testRtpOk(ffmpeg, work)
        "rtp-loss" -> testRtpLoss(ffmpeg, work)
        "proto" -> testProto()
        else -> { println("unknown mode $mode"); exitProcess(2) }
    }
    println(if (failures == 0) "PASSED" else "FAILED ($failures)")
    exitProcess(if (failures == 0) 0 else 1)
}
