package com.phonevr

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.Surface
import java.util.concurrent.atomic.AtomicBoolean
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/** Everything the shader needs, already converted to screen pixels. Immutable: swap the whole object. */
class StereoParams(
    val lensSepPx: Float,
    val focalPx: Float,
    val vOffsetPx: Float,
    val k1: Float,
    val k2: Float,
    val tanX: Float,
    val tanY: Float,
    val halfTexel: Float,
    val pattern: Boolean,
)

/**
 * Draws the side-by-side video as two lens-corrected eye views, in one full-screen pass at the panel's native
 * resolution. For every screen pixel: offset from that eye's lens centre -> tan angle -> radial lens model ->
 * position in the eye image -> sample the decoded frame (external OES texture).
 */
class StereoRenderer(private val listener: Listener) : GLSurfaceView.Renderer {
    interface Listener {
        /** GL thread. The decoder must render into this surface. */
        fun onSurfaceReady(surface: Surface)
    }

    @Volatile var params: StereoParams = StereoParams(0f, 1f, 0f, 0f, 0f, 1f, 1f, 0.0005f, true)
    @Volatile var hasVideo = false; private set

    private var program = 0
    private var texId = 0
    private var surfaceTexture: SurfaceTexture? = null
    private var surface: Surface? = null
    private val newFrame = AtomicBoolean(false)
    private val texMatrix = FloatArray(16)
    private var width = 1
    private var height = 1
    private val loc = HashMap<String, Int>()

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        hasVideo = false
        newFrame.set(false)
        program = buildProgram(VERTEX, FRAGMENT)
        for (n in listOf("uVideo", "uTexMatrix", "uSurface", "uLensSepPx", "uFocalPx", "uVOffsetPx", "uK", "uTan", "uEdge", "uPattern"))
            loc[n] = GLES30.glGetUniformLocation(program, n)

        val t = IntArray(1)
        GLES30.glGenTextures(1, t, 0)
        texId = t[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        android.opengl.Matrix.setIdentityM(texMatrix, 0)

        releaseSurface()
        val st = SurfaceTexture(texId)
        st.setOnFrameAvailableListener { newFrame.set(true) }
        surfaceTexture = st
        val s = Surface(st)
        surface = s
        listener.onSurfaceReady(s)
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        width = w
        height = h
    }

    override fun onDrawFrame(gl: GL10?) {
        val st = surfaceTexture
        if (st != null && newFrame.getAndSet(false)) {
            try {
                st.updateTexImage()
                st.getTransformMatrix(texMatrix)
                hasVideo = true
            } catch (e: RuntimeException) {
                Log.w(TAG, "updateTexImage: ${e.message}")
            }
        }
        val p = params
        GLES30.glViewport(0, 0, width, height)
        GLES30.glUseProgram(program)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES30.glUniform1i(loc["uVideo"]!!, 0)
        GLES30.glUniformMatrix4fv(loc["uTexMatrix"]!!, 1, false, texMatrix, 0)
        GLES30.glUniform2f(loc["uSurface"]!!, width.toFloat(), height.toFloat())
        GLES30.glUniform1f(loc["uLensSepPx"]!!, p.lensSepPx)
        GLES30.glUniform1f(loc["uFocalPx"]!!, p.focalPx)
        GLES30.glUniform1f(loc["uVOffsetPx"]!!, p.vOffsetPx)
        GLES30.glUniform2f(loc["uK"]!!, p.k1, p.k2)
        GLES30.glUniform2f(loc["uTan"]!!, p.tanX, p.tanY)
        GLES30.glUniform1f(loc["uEdge"]!!, p.halfTexel)
        GLES30.glUniform1i(loc["uPattern"]!!, if (p.pattern || !hasVideo) 1 else 0)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
    }

    /** Call after the decoder using the surface has been stopped. */
    fun releaseSurface() {
        hasVideo = false
        try { surface?.release() } catch (_: Exception) { }
        try { surfaceTexture?.release() } catch (_: Exception) { }
        surface = null
        surfaceTexture = null
    }

    private fun buildProgram(vs: String, fs: String): Int {
        val v = compile(GLES30.GL_VERTEX_SHADER, vs)
        val f = compile(GLES30.GL_FRAGMENT_SHADER, fs)
        val p = GLES30.glCreateProgram()
        GLES30.glAttachShader(p, v)
        GLES30.glAttachShader(p, f)
        GLES30.glLinkProgram(p)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) throw RuntimeException("link failed: " + GLES30.glGetProgramInfoLog(p))
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES30.glCreateShader(type)
        GLES30.glShaderSource(s, src)
        GLES30.glCompileShader(s)
        val ok = IntArray(1)
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) throw RuntimeException("shader failed: " + GLES30.glGetShaderInfoLog(s))
        return s
    }

    private companion object {
        const val TAG = "PhoneVR"

        const val VERTEX = """#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""

        const val FRAGMENT = """#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES uVideo;
uniform mat4 uTexMatrix;
uniform vec2 uSurface;
uniform float uLensSepPx;
uniform float uFocalPx;
uniform float uVOffsetPx;
uniform vec2 uK;
uniform vec2 uTan;
uniform float uEdge;
uniform int uPattern;
out vec4 outColor;

void main() {
    vec2 frag = vec2(gl_FragCoord.x, uSurface.y - gl_FragCoord.y);
    bool leftEye = frag.x < 0.5 * uSurface.x;
    float cx = 0.5 * uSurface.x + (leftEye ? -0.5 : 0.5) * uLensSepPx;
    vec2 p = frag - vec2(cx, 0.5 * uSurface.y + uVOffsetPx);
    vec2 t = p / uFocalPx;
    float r2 = dot(t, t);
    t *= 1.0 + r2 * (uK.x + r2 * uK.y);
    vec2 e = 0.5 + t / (2.0 * uTan);
    if (e.x < 0.0 || e.x > 1.0 || e.y < 0.0 || e.y > 1.0) {
        outColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    if (uPattern == 1) {
        vec2 g = e * 10.0;
        vec2 d = abs(fract(g + 0.5) - 0.5) / max(fwidth(g), vec2(1e-6));
        float line = 1.0 - min(min(d.x, d.y), 1.0);
        vec3 base = leftEye ? vec3(0.1, 0.6, 1.0) : vec3(1.0, 0.5, 0.1);
        vec3 col = base * line;
        vec2 c = abs(e - 0.5) / max(fwidth(e), vec2(1e-6));
        if (min(c.x, c.y) < 2.0) col = vec3(1.0);
        outColor = vec4(col, 1.0);
        return;
    }
    vec2 uv = vec2(((leftEye ? 0.0 : 1.0) + e.x) * 0.5, 1.0 - e.y);
    float lo = leftEye ? 0.0 : 0.5;
    uv.x = clamp(uv.x, lo + uEdge, lo + 0.5 - uEdge);
    vec2 st = (uTexMatrix * vec4(uv, 0.0, 1.0)).xy;
    outColor = vec4(texture(uVideo, st).rgb, 1.0);
}
"""
    }
}
