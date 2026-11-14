package dev.nativechrome.native_chrome

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Installs native bars automatically on the Activity hosting the engine, as an
 * overlay sibling of the FlutterView. Keeps the last state so a recreated
 * Activity (configuration change) gets the same bars back.
 */
class NativeChromePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var overlay: NativeChromeOverlay? = null
    private val connection = NativeChromeConnection()
    private val icons = HashMap<String, Bitmap>()
    private var iconVersion = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "native_chrome/host").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun send(method: String, args: Map<String, Any?>) {
        channel?.invokeMethod(method, args)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "attach" -> {
                val args = call.arguments as? Map<*, *>
                val lease = args?.get("lease") as? String
                if ((args?.get("protocol") as? Number)?.toInt() != 2 || lease == null) {
                    result.error("bad-protocol", "native_chrome protocol 2 required", null)
                    return
                }
                if (connection.attach(lease)) overlay?.clear()
                val reply = mutableMapOf<String, Any?>(
                    "protocol" to 2,
                    "platform" to "android",
                    "lease" to lease,
                    // The overlay is installed right after the Activity's content view.
                    "hostInstalled" to (activity != null),
                )
                overlay?.let { reply["geometry"] = it.geometry() }
                result.success(reply)
            }
            "update" -> {
                val state = NativeChromeStateSpec.parse(call.arguments)
                if (state == null) {
                    result.error("bad-state", "Unsupported native_chrome state", null)
                    return
                }
                if (connection.accept(state)) overlay?.apply(state)
                result.success(null)
            }
            "detach" -> {
                val lease = (call.arguments as? Map<*, *>)?.get("lease") as? String
                if (lease != null && connection.detach(lease)) overlay?.clear()
                result.success(null)
            }
            "icons" -> {
                (call.arguments as? Map<*, *>)?.forEach { (key, value) ->
                    val entry = value as? Map<*, *> ?: return@forEach
                    val bytes = entry["png"] as? ByteArray ?: return@forEach
                    val scale = (entry["scale"] as? Number)?.toFloat() ?: 1f
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@forEach
                    bitmap.density = (scale * 160).toInt()
                    icons[key as String] = bitmap
                }
                iconVersion += 1
                overlay?.iconVersion = iconVersion
                overlay?.reapply()
                result.success(null)
            }
            "transition" -> {
                (call.arguments as? Map<*, *>)?.let {
                    if (it["lease"] == connection.lease) overlay?.transition(it)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun install(activity: Activity) {
        this.activity = activity
        // Defer until the Activity has set its content view (FlutterActivity
        // attaches plugins before setContentView).
        activity.window.decorView.post {
            if (this.activity !== activity || overlay != null) return@post
            val content = activity.findViewById<ViewGroup>(android.R.id.content) ?: return@post
            val view = NativeChromeOverlay(activity, ::send, connection::nextRequestId) { spec -> spec?.let { icons[it.key] } }
            content.addView(view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            overlay = view
            view.iconVersion = iconVersion
            connection.lastState?.let { view.apply(it) }
            view.post {
                send("hostReady", mapOf("hostInstalled" to true, "geometry" to view.geometry(), "lease" to connection.lease))
            }
        }
    }

    private fun uninstall() {
        overlay?.let { (it.parent as? ViewGroup)?.removeView(it) }
        overlay = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = install(binding.activity)
    override fun onDetachedFromActivityForConfigChanges() = uninstall()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = install(binding.activity)
    override fun onDetachedFromActivity() = uninstall()
}
