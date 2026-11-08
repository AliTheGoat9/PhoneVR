package com.phonevr

import android.app.Activity
import android.content.pm.ActivityInfo
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.SurfaceHolder
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Toast
import com.phonevr.core.PcConfig

/**
 * The headset view. Put the phone in the headset after pressing Start.
 *   Volume up / down  eye separation +/- 0.5 mm (IPD; moves the lens separation too when linked)
 *   Tap the screen    recenter (make the direction you face "forward")
 */
class VrActivity : Activity(), StereoRenderer.Listener, Session.Listener {
    private lateinit var settings: AppSettings
    private lateinit var glView: GLSurfaceView
    private lateinit var renderer: StereoRenderer
    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null
    private var calibration = false
    @Volatile private var config: PcConfig? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        calibration = intent.getBooleanExtra(EXTRA_CALIBRATION, false)
        settings = AppSettings.load(this)

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val lp = window.attributes
        lp.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_FULL
        lp.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        // Ask for the panel's full resolution at the highest refresh rate that reaches the PC's rate.
        display?.let { d -> DisplayUtil.bestMode(d, TARGET_HZ)?.let { lp.preferredDisplayModeId = it.modeId } }
        window.attributes = lp

        renderer = StereoRenderer(this)
        glView = GLSurfaceView(this).apply {
            setEGLContextClientVersion(3)
            preserveEGLContextOnPause = false
            setRenderer(renderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) {
                    h.surface.setFrameRate(
                        config?.displayHz ?: TARGET_HZ,
                        Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
                        Surface.CHANGE_FRAME_RATE_ALWAYS,
                    )
                }
                override fun surfaceChanged(h: SurfaceHolder, format: Int, w: Int, hgt: Int) { updateParams() }
                override fun surfaceDestroyed(h: SurfaceHolder) {}
            })
        }
        setContentView(glView)
        updateParams()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
        glView.onResume()
    }

    override fun onPause() {
        stopSession()
        glView.onPause()
        renderer.releaseSurface()
        super.onPause()
    }

    // --- StereoRenderer.Listener (GL thread) ---
    override fun onSurfaceReady(surface: Surface) {
        main.post { startSession(surface) }
    }

    // --- Session.Listener (worker threads) ---
    override fun onConfig(cfg: PcConfig) {
        config = cfg
        main.post { updateParams() }
    }

    override fun onError(msg: String) {
        main.post { Toast.makeText(this, msg, Toast.LENGTH_LONG).show() }
    }

    private fun startSession(surface: Surface) {
        stopSession()
        if (isFinishing || calibration) return
        if (settings.pcIp.isBlank()) {
            Toast.makeText(this, "Enter the PC's IP address first.", Toast.LENGTH_LONG).show()
            finish()
            return
        }
        session = Session(this, settings, surface, { display?.rotation == Surface.ROTATION_270 }, this).also { it.start() }
    }

    private fun stopSession() {
        session?.stop()
        session = null
    }

    /** Converts the millimetre settings to screen pixels for the shader. */
    private fun updateParams() {
        val dm = resources.displayMetrics
        val ppi = if (settings.ppiOverride > 50f) settings.ppiOverride else dm.xdpi
        val pxPerMm = ppi / 25.4f
        val cfg = config
        val tanX = cfg?.tanHalfX ?: 1.19f
        val tanY = cfg?.tanHalfY ?: 1.07f
        val videoW = (cfg?.videoWidth ?: 2992).toFloat()
        renderer.params = StereoParams(
            lensSepPx = settings.lensSepMm * pxPerMm,
            focalPx = settings.lensDistMm * pxPerMm,
            vOffsetPx = -settings.vOffsetMm * pxPerMm,   // +mm = image moves up the screen
            k1 = settings.k1,
            k2 = settings.k2,
            tanX = tanX,
            tanY = tanY,
            halfTexel = 0.5f / videoW,
            pattern = calibration,
        )
    }

    private fun adjustIpd(deltaMm: Float) {
        settings.setIpd(settings.ipdMm + deltaMm)
        settings.save(this)
        session?.ipdMm = settings.ipdMm
        updateParams()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_VOLUME_UP -> { adjustIpd(+0.5f); true }
        KeyEvent.KEYCODE_VOLUME_DOWN -> { adjustIpd(-0.5f); true }
        else -> super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) true
        else super.onKeyUp(keyCode, event)

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) session?.recenter()
        return true
    }

    private fun hideSystemBars() {
        window.insetsController?.let {
            it.hide(WindowInsets.Type.systemBars())
            it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    companion object {
        const val EXTRA_CALIBRATION = "calibration"
        private const val TARGET_HZ = 120f
    }
}
