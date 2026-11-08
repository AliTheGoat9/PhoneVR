package com.phonevr

import android.content.Context
import com.phonevr.core.Protocol

/** Everything the user can tune. Stored in SharedPreferences, edited on [SettingsActivity], read by [VrActivity]. */
class AppSettings {
    var pcIp: String = ""
    var videoPort: Int = Protocol.DEFAULT_VIDEO_PORT
    var configPort: Int = Protocol.DEFAULT_CONFIG_PORT
    var posePort: Int = Protocol.DEFAULT_POSE_PORT

    /** Interpupillary distance in mm. Sent to SteamVR: it is the eye separation the game renders with. */
    var ipdMm: Float = 63f

    /** Distance between the two lens centres in mm. Where the two eye images are centred on the screen. */
    var lensSepMm: Float = 63f

    /** While true, changing the IPD also moves the lens separation (right for most headsets). */
    var linkLensToIpd: Boolean = true

    /** Screen-to-lens distance in mm. Larger = image looks smaller / wider field of view is not reached. */
    var lensDistMm: Float = 42f

    /** Radial distortion of the lens, pincushion compensation: tanView = tanScreen * (1 + k1 r^2 + k2 r^4). */
    var k1: Float = 0.34f
    var k2: Float = 0.55f

    /** Moves both eye images up (+) or down (-) on the screen, in mm. */
    var vOffsetMm: Float = 0f

    /** 0 = use the pixel density Android reports. */
    var ppiOverride: Float = 0f

    /** After a lost packet, freeze the picture until the next keyframe instead of showing smeared artefacts. */
    var freezeOnLoss: Boolean = false

    fun setIpd(mm: Float) {
        ipdMm = mm.coerceIn(IPD_MIN, IPD_MAX)
        if (linkLensToIpd) lensSepMm = ipdMm
    }

    fun resetLens() {
        lensDistMm = 42f; k1 = 0.34f; k2 = 0.55f; vOffsetMm = 0f
    }

    fun save(ctx: Context) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("pcIp", pcIp)
            .putInt("videoPort", videoPort).putInt("configPort", configPort).putInt("posePort", posePort)
            .putFloat("ipdMm", ipdMm).putFloat("lensSepMm", lensSepMm).putBoolean("linkLensToIpd", linkLensToIpd)
            .putFloat("lensDistMm", lensDistMm).putFloat("k1", k1).putFloat("k2", k2)
            .putFloat("vOffsetMm", vOffsetMm).putFloat("ppiOverride", ppiOverride)
            .putBoolean("freezeOnLoss", freezeOnLoss)
            .apply()
    }

    companion object {
        private const val PREFS = "phonevr"
        const val IPD_MIN = 50f
        const val IPD_MAX = 80f

        fun load(ctx: Context): AppSettings {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val d = AppSettings()
            return d.apply {
                pcIp = p.getString("pcIp", pcIp) ?: pcIp
                videoPort = p.getInt("videoPort", videoPort)
                configPort = p.getInt("configPort", configPort)
                posePort = p.getInt("posePort", posePort)
                ipdMm = p.getFloat("ipdMm", ipdMm)
                lensSepMm = p.getFloat("lensSepMm", lensSepMm)
                linkLensToIpd = p.getBoolean("linkLensToIpd", linkLensToIpd)
                lensDistMm = p.getFloat("lensDistMm", lensDistMm)
                k1 = p.getFloat("k1", k1)
                k2 = p.getFloat("k2", k2)
                vOffsetMm = p.getFloat("vOffsetMm", vOffsetMm)
                ppiOverride = p.getFloat("ppiOverride", ppiOverride)
                freezeOnLoss = p.getBoolean("freezeOnLoss", freezeOnLoss)
            }
        }
    }
}
