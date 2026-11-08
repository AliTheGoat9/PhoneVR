package com.phonevr

import android.view.Display

object DisplayUtil {
    /**
     * Highest-resolution display mode, and within that resolution the refresh rate closest to [targetHz],
     * preferring modes that reach it over modes that fall short.
     */
    fun bestMode(display: Display, targetHz: Float): Display.Mode? {
        val modes = display.supportedModes
        if (modes.isNullOrEmpty()) return null
        val maxPixels = modes.maxOf { it.physicalWidth.toLong() * it.physicalHeight }
        return modes
            .filter { it.physicalWidth.toLong() * it.physicalHeight == maxPixels }
            .minByOrNull { m ->
                val d = m.refreshRate - targetHz
                if (d >= -0.5f) d else 1000f - d
            }
    }

    fun describe(m: Display.Mode): String =
        "${m.physicalWidth}x${m.physicalHeight} @ ${"%.0f".format(m.refreshRate)} Hz"
}
