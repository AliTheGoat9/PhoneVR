package com.phonevr

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView

/** Launcher screen: connection, eye separation, lens tuning. Built in code so the project needs no XML resources. */
class SettingsActivity : Activity() {
    private lateinit var s: AppSettings
    private lateinit var root: LinearLayout
    private val sliderRefreshers = ArrayList<() -> Unit>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        s = AppSettings.load(this)
        val pad = (16 * resources.displayMetrics.density).toInt()
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(pad, pad * 2, pad, pad) }
        setContentView(ScrollView(this).apply { addView(root) })
        build()
    }

    private fun build() {
        root.removeAllViews()
        sliderRefreshers.clear()

        title("PhoneVR")
        note(displayInfo())

        header("Connection")
        val ip = EditText(this).apply {
            hint = "PC IPv4 address, e.g. 192.168.1.20"
            setText(s.pcIp)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine()
        }
        root.addView(ip)
        ip.setOnFocusChangeListener { _, _ -> s.pcIp = ip.text.toString().trim() }

        header("Eyes")
        slider("IPD (eye separation sent to SteamVR)", AppSettings.IPD_MIN, AppSettings.IPD_MAX, 0.5f, { s.ipdMm }, "mm") {
            s.setIpd(it)
            sliderRefreshers.forEach { r -> r() }
        }
        slider("Lens separation (centre of each eye image)", 50f, 80f, 0.5f, { s.lensSepMm }, "mm") { s.lensSepMm = it }
        check("Link lens separation to IPD", s.linkLensToIpd) { s.linkLensToIpd = it }
        slider("Vertical offset", -10f, 10f, 0.5f, { s.vOffsetMm }, "mm") { s.vOffsetMm = it }

        header("Lenses")
        slider("Screen-to-lens distance (bigger = smaller picture)", 25f, 70f, 0.5f, { s.lensDistMm }, "mm") { s.lensDistMm = it }
        slider("Distortion k1", 0f, 1.0f, 0.01f, { s.k1 }, "") { s.k1 = it }
        slider("Distortion k2", 0f, 1.5f, 0.01f, { s.k2 }, "") { s.k2 = it }
        button("Reset lens values") { s.resetLens(); s.save(this); build() }

        header("Stream")
        check("Freeze picture after packet loss until next keyframe", s.freezeOnLoss) { s.freezeOnLoss = it }
        note("Off = brief smearing after a lost packet (usually better). On = frozen picture, can stall on bad Wi-Fi.")

        header("Advanced")
        intField("Video port (RTP from ffmpeg)", s.videoPort) { s.videoPort = it }
        intField("Config port (from driver)", s.configPort) { s.configPort = it }
        intField("Pose port (to driver)", s.posePort) { s.posePort = it }
        intField("Screen PPI override (0 = automatic, Android reports ${"%.0f".format(resources.displayMetrics.xdpi)})", s.ppiOverride.toInt()) { s.ppiOverride = it.toFloat() }

        header("")
        button("Calibration grid (check lens fit, no PC needed)") { launch(true, ip) }
        button("START - then put the phone in the headset") { launch(false, ip) }
        note("In the headset: volume keys change IPD, tap = recenter.")
    }

    private fun launch(calibration: Boolean, ip: EditText) {
        s.pcIp = ip.text.toString().trim()
        s.save(this)
        startActivity(Intent(this, VrActivity::class.java).putExtra(VrActivity.EXTRA_CALIBRATION, calibration))
    }

    override fun onPause() {
        super.onPause()
        s.save(this)
    }

    private fun displayInfo(): String {
        val d = display ?: return ""
        val modes = d.supportedModes.joinToString(", ") { DisplayUtil.describe(it) }
        val best = DisplayUtil.bestMode(d, 120f)?.let { DisplayUtil.describe(it) } ?: "?"
        return "The app will ask Android for: $best\nSupported display modes: $modes"
    }

    // --- tiny view helpers ---
    private fun title(t: String) = root.addView(TextView(this).apply { text = t; textSize = 26f })
    private fun header(t: String) = root.addView(TextView(this).apply { text = t; textSize = 18f; setPadding(0, 40, 0, 8) })
    private fun note(t: String) = root.addView(TextView(this).apply { text = t; textSize = 13f; setPadding(0, 8, 0, 8) })

    private fun button(t: String, onClick: () -> Unit) =
        root.addView(Button(this).apply { text = t; setOnClickListener { onClick() } })

    private fun check(t: String, initial: Boolean, onChange: (Boolean) -> Unit) =
        root.addView(CheckBox(this).apply { text = t; isChecked = initial; setOnCheckedChangeListener { _, v -> onChange(v) } })

    private fun intField(label: String, initial: Int, onChange: (Int) -> Unit) {
        root.addView(TextView(this).apply { text = label; textSize = 13f })
        root.addView(EditText(this).apply {
            setText(initial.toString())
            inputType = InputType.TYPE_CLASS_NUMBER
            setSingleLine()
            setOnFocusChangeListener { _, _ -> text.toString().toIntOrNull()?.let(onChange) }
        })
    }

    /** Label + live value + SeekBar. [refresh] lets other sliders update this one (IPD drives lens separation). */
    private fun slider(label: String, min: Float, max: Float, step: Float, get: () -> Float, unit: String, onChange: (Float) -> Unit) {
        val text = TextView(this).apply { textSize = 14f; setPadding(0, 16, 0, 0) }
        val bar = SeekBar(this).apply { this.max = Math.round((max - min) / step) }
        fun show() {
            val v = get()
            text.text = "$label: ${"%.2f".format(v)} $unit".trim()
            bar.progress = Math.round((v - min) / step)
        }
        bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(sb: SeekBar, p: Int, fromUser: Boolean) {
                if (!fromUser) return
                onChange(min + p * step)
                text.text = "$label: ${"%.2f".format(get())} $unit".trim()
            }
            override fun onStartTrackingTouch(sb: SeekBar) {}
            override fun onStopTrackingTouch(sb: SeekBar) {}
        })
        sliderRefreshers.add { show() }
        show()
        root.addView(text)
        root.addView(bar)
    }

    @Suppress("unused") private fun gone(v: View) { v.visibility = View.GONE }
}
