package com.phonevr

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import android.view.Surface
import com.phonevr.core.PcConfig

/** One streaming run: network + decoder + head tracking. Created when the GL surface exists, stopped on pause. */
class Session(
    private val ctx: Context,
    private val settings: AppSettings,
    private val surface: Surface,
    private val landscapeRight: () -> Boolean,
    private val listener: Listener,
) {
    interface Listener {
        fun onConfig(cfg: PcConfig)
        fun onError(msg: String)
    }

    /** Read by the sensor thread for every pose packet. */
    @Volatile var ipdMm: Float = settings.ipdMm

    private val lock = Any()
    private var stopped = false
    private var link: StreamLink? = null
    private var decoder: VideoDecoder? = null
    private var tracker: HeadTracker? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var lastCfg: PcConfig? = null

    fun start() {
        Thread({ doStart() }, "phonevr-session").start()
    }

    private fun doStart() {
        val l = StreamLink(settings.pcIp, settings.posePort, settings.configPort, settings.videoPort, settings.freezeOnLoss)
        l.onConfig = { cfg -> handleConfig(cfg) }
        l.onAccessUnit = { data, size, _ -> decoder?.queue(data, size) }
        val err = l.start()
        if (err != null) { listener.onError(err); return }

        synchronized(lock) {
            if (stopped) { l.stop(); return }
            link = l
            try {
                val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "phonevr").also { it.acquire() }
            } catch (e: Exception) {
                Log.w(TAG, "wifi lock: ${e.message}")
            }
            val t = HeadTracker(ctx, { b, n -> l.sendPose(b, n) }, { ipdMm }, landscapeRight)
            if (!t.start()) { listener.onError("This phone has no rotation sensor."); return }
            tracker = t
        }
    }

    private fun handleConfig(cfg: PcConfig) {
        synchronized(lock) {
            if (stopped) return
            if (cfg != lastCfg) { lastCfg = cfg; listener.onConfig(cfg) }
            val d = decoder
            if (d == null || d.width != cfg.videoWidth || d.height != cfg.videoHeight) {
                d?.stop()
                val nd = VideoDecoder(surface, cfg.videoWidth, cfg.videoHeight, cfg.displayHz)
                decoder = if (nd.start()) nd else null
                if (decoder == null) listener.onError("Could not start the H.265 decoder.")
            }
        }
    }

    fun recenter() { tracker?.requestRecenter() }

    fun stop() {
        synchronized(lock) {
            stopped = true
            tracker?.stop(); tracker = null
            link?.stop(); link = null
            decoder?.stop(); decoder = null
            try { wifiLock?.release() } catch (_: Exception) { }
            wifiLock = null
        }
    }

    private companion object { const val TAG = "PhoneVR" }
}
