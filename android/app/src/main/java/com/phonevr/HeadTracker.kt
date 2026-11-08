package com.phonevr

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import com.phonevr.core.PoseWriter
import com.phonevr.core.Protocol

/**
 * Samples the game rotation vector (gyro + accelerometer fusion, no magnetometer so no compass jitter) and the raw
 * gyro at the fastest rate the hardware offers, and sends one PosePacket per rotation sample.
 * Use one instance per session: the sampling thread cannot be restarted.
 */
class HeadTracker(
    context: Context,
    private val send: (ByteArray, Int) -> Unit,
    private val ipdMm: () -> Float,
    private val landscapeRight: () -> Boolean,
) : SensorEventListener {
    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotation: Sensor? =
        sm.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR) ?: sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val gyroSensor: Sensor? = sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

    private val thread = HandlerThread("phonevr-pose", Process.THREAD_PRIORITY_URGENT_DISPLAY)
    private val writer = PoseWriter()
    private val wxyz = FloatArray(4)
    private val xyzw = FloatArray(4)
    private val gyro = FloatArray(3)
    @Volatile private var recenterUntil = 0L

    /** Returns false if the phone has no rotation sensor. */
    fun start(): Boolean {
        val r = rotation ?: return false
        thread.start()
        val handler = Handler(thread.looper)
        sm.registerListener(this, r, SensorManager.SENSOR_DELAY_FASTEST, handler)
        gyroSensor?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_FASTEST, handler) }
        return true
    }

    fun stop() {
        sm.unregisterListener(this)
        thread.quitSafely()
    }

    /** Asks the driver to make the current facing direction "forward". */
    fun requestRecenter() {
        recenterUntil = SystemClock.elapsedRealtime() + 300
    }

    override fun onSensorChanged(e: SensorEvent) {
        if (e.sensor.type == Sensor.TYPE_GYROSCOPE) {
            gyro[0] = e.values[0]; gyro[1] = e.values[1]; gyro[2] = e.values[2]
            return
        }
        SensorManager.getQuaternionFromVector(wxyz, e.values)   // -> w, x, y, z
        xyzw[0] = wxyz[1]; xyzw[1] = wxyz[2]; xyzw[2] = wxyz[3]; xyzw[3] = wxyz[0]
        var flags = 0
        if (landscapeRight()) flags = flags or Protocol.FLAG_LANDSCAPE_RIGHT
        if (SystemClock.elapsedRealtime() < recenterUntil) flags = flags or Protocol.FLAG_RECENTER
        val n = writer.write(flags, e.timestamp, xyzw, gyro, ipdMm())
        send(writer.buffer, n)
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
