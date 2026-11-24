package dev.nativechrome.native_chrome

import android.app.Activity
import android.content.ComponentName
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

private const val OVERLAY_ENABLED = "dev.nativechrome.overlayEnabled"

// An engine can recreate its plugin while the same Dart isolate is alive.
private val nextHostGeneration = AtomicInteger()

/**
 * Installs native bars automatically on the Activity hosting the engine, as an
 * overlay sibling of the FlutterView. Keeps the last state so a recreated
 * Activity (configuration change) gets the same bars back.
 */
class NativeChromePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var overlay: NativeChromeOverlay? = null
    private var activityLifecycle: Lifecycle? = null
    private val lifecycleObserver = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_PAUSE) overlay?.toolbar?.dismissPopupMenus()
    }
    private var hostGeneration = 0
    private val connection = NativeChromeConnection()
    private val icons = HashMap<String, Bitmap>()
    private var iconVersion = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        hostGeneration = nextHostGeneration.incrementAndGet()
        channel = MethodChannel(binding.binaryMessenger, "native_chrome/host").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (activity != null || overlay != null) uninstall()
        connection.lease?.let { connection.detach(it) }
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
                    "hostGeneration" to hostGeneration,
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

    @Suppress("DEPRECATION") // The int-flags overload also supports API 24–32.
    private fun overlayEnabled(activity: Activity): Boolean {
        // The launch intent can name an alias. Read the concrete activity's
        // metadata so all entry points to the same class share the policy.
        val component = ComponentName(activity.packageName, activity.javaClass.name)
        return try {
            activity.packageManager.getActivityInfo(component, PackageManager.GET_META_DATA)
                .metaData?.getBoolean(OVERLAY_ENABLED, true) ?: true
        } catch (_: PackageManager.NameNotFoundException) {
            true
        }
    }

    private fun publishHostReady(installed: Boolean) {
        val info = mutableMapOf<String, Any?>(
            "hostInstalled" to installed,
            "lease" to connection.lease,
            "hostGeneration" to hostGeneration,
        )
        overlay?.let { info["geometry"] = it.geometry() }
        send("hostReady", info)
    }

    private fun install(activity: Activity) {
        val generation = nextHostGeneration.incrementAndGet()
        hostGeneration = generation
        if (!overlayEnabled(activity)) {
            publishHostReady(false)
            return
        }
        this.activity = activity
        activityLifecycle = (activity as? LifecycleOwner)?.lifecycle
        activityLifecycle?.addObserver(lifecycleObserver)
        // Defer until the Activity has set its content view (FlutterActivity
        // attaches plugins before setContentView).
        activity.window.decorView.post {
            if (this.activity !== activity || hostGeneration != generation || overlay != null) return@post
            val content = activity.findViewById<ViewGroup>(android.R.id.content)
            if (content == null) {
                this.activity = null
                removeActivityLifecycleObserver()
                publishHostReady(false)
                return@post
            }
            val view = createOverlay(activity, generation)
            // Current before it is attached: only the current overlay sends.
            overlay = view
            content.addView(view, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
            view.iconVersion = iconVersion
            connection.lastState?.let { view.apply(it) }
            view.post {
                if (hostGeneration == generation && this.activity === activity && overlay === view) {
                    publishHostReady(true)
                }
            }
        }
    }

    private fun createOverlay(activity: Activity, generation: Int): NativeChromeOverlay {
        lateinit var view: NativeChromeOverlay
        view = NativeChromeOverlay(activity, sendFromView@{ method, args ->
            if (hostGeneration == generation && this.activity === activity && overlay === view) {
                if (args["androidOverflow"] == true && activityLifecycle?.currentState != Lifecycle.State.RESUMED) {
                    return@sendFromView
                }
                val scoped = args + ("hostGeneration" to generation)
                send(method, if (method == "geometry") scoped + ("lease" to connection.lease) else scoped)
            }
        }, connection::nextRequestId) { spec -> spec?.let { icons[it.key] } }
        view.onMetricsChanged = { replaceOverlay(activity, generation, view) }
        return view
    }

    /**
     * The activity handled a font size or display size change: the bars'
     * framework views keep sizes converted when they were built, so install a
     * fresh overlay in the same place with the same host generation and state.
     * The overlay defers this while a bar transition runs. The replaced view
     * stops its animation and deferred work and can no longer send events;
     * the new one continues its popup dim and shows the current selection.
     */
    private fun replaceOverlay(activity: Activity, generation: Int, old: NativeChromeOverlay) {
        if (hostGeneration != generation || this.activity !== activity || overlay !== old) return
        val content = old.parent as? ViewGroup ?: return
        val index = content.indexOfChild(old)
        val view = createOverlay(activity, generation)
        view.iconVersion = iconVersion
        view.inheritPresentation(old)
        overlay = view
        old.dispose()
        content.removeView(old)
        content.addView(view, index, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        connection.lastState?.let { view.apply(it) }
    }

    private fun uninstall() {
        hostGeneration = nextHostGeneration.incrementAndGet()
        removeActivityLifecycleObserver()
        overlay?.toolbar?.dismissPopupMenus()
        overlay?.let { (it.parent as? ViewGroup)?.removeView(it) }
        overlay = null
        activity = null
        connection.clearHostState()
        if (connection.lease != null) publishHostReady(false)
    }

    private fun removeActivityLifecycleObserver() {
        activityLifecycle?.removeObserver(lifecycleObserver)
        activityLifecycle = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = install(binding.activity)
    override fun onDetachedFromActivityForConfigChanges() = uninstall()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = install(binding.activity)
    override fun onDetachedFromActivity() = uninstall()
}
