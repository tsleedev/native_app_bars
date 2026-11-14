package dev.nativechrome.native_chrome

import android.graphics.drawable.Drawable
import android.view.Gravity
import android.view.View
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.LifecycleOwner

/** A top toolbar in a host-owned frame. Call on the Android main thread. */
class EmbeddedNativeTopBar(
    private val slot: FrameLayout,
    lifecycleOwner: LifecycleOwner,
    private val onVisibilityChanged: (Boolean) -> Unit = {},
    private val onAction: (String) -> Unit,
) : AutoCloseable {
    data class Action(
        val id: String,
        val label: String,
        val enabled: Boolean = true,
        val overflowIfRoom: Boolean = false,
    )

    data class Content(
        val title: String,
        val back: Action? = null,
        val backIcon: Drawable? = null,
        val actions: List<Action> = emptyList(),
        val foreground: Int? = null,
        val background: Int? = null,
    )

    private val ownership = EmbeddedTopBarOwnership()
    private var fallback: View? = null
    private var fallbackVisibility = View.VISIBLE
    private var displayedContent: Content? = null
    private var displayedLayoutDirection: Int? = null
    private var active = false
    private var closed = false
    private var showing = false
    private var pending: ViewTreeObserver.OnPreDrawListener? = null
    private var preDrawObserver: ViewTreeObserver? = null
    private val renderer = NativeChromeOverlay(slot.context, ::receive, { 0 }, { null }).apply {
        hostOwnsInsets = true
    }
    private val lifecycle = lifecycleOwner.lifecycle
    private val observer = LifecycleEventObserver { _, event ->
        when (event) {
            Lifecycle.Event.ON_PAUSE -> hide()
            Lifecycle.Event.ON_DESTROY -> close()
            else -> Unit
        }
    }
    private val attachment = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) = Unit
        override fun onViewDetachedFromWindow(view: View) = hide()
    }
    private val layout = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        if (displayedLayoutDirection != slot.layoutDirection) {
            updateLayoutDirection()
        }
    }

    init {
        lifecycle.addObserver(observer)
        slot.addOnAttachStateChangeListener(attachment)
        slot.addOnLayoutChangeListener(layout)
    }

    /**
     * Requests a replacement. The existing bar remains active until the new
     * toolbar has a nonzero layout. The visibility callback reports the swap.
     * Pass effective top and physical horizontal insets in pixels. A false
     * result rejects the request. After pause, only a current route may reshow.
     */
    fun show(
        existingBar: View,
        content: Content,
        insetLeft: Int = 0,
        insetTop: Int = 0,
        insetRight: Int = 0,
        enabled: Boolean = true,
    ): Boolean {
        if (closed || !slot.isAttachedToWindow || existingBar.parent !== slot ||
            lifecycle.currentState != Lifecycle.State.RESUMED ||
            insetLeft < 0 || insetTop < 0 || insetRight < 0 ||
            slot.width - insetLeft - insetRight <= 0 ||
            (content.back != null && content.backIcon == null)
        ) {
            hide()
            return false
        }
        if (fallback !== existingBar) hide()
        if (renderer.paddingLeft != insetLeft || renderer.paddingTop != insetTop || renderer.paddingRight != insetRight) {
            renderer.setPadding(insetLeft, insetTop, insetRight, 0)
        }
        val changed = displayedContent != content || active != enabled || displayedLayoutDirection != slot.layoutDirection
        if (!changed) return true
        renderer.nativeLeadingIcon = content.backIcon
        renderer.toolbar.dismissPopupMenus()
        updateLayoutDirection()
        renderer.iconVersion++
        val revision = ownership.replace()
        active = enabled
        displayedContent = content
        displayedLayoutDirection = slot.layoutDirection
        renderer.apply(
            NativeChromeStateSpec(
                lease = "",
                revision = revision,
                top = NativeChromeTopSpec(
                    stamp = NativeChromeOwnerStamp(0, 0, revision),
                    title = content.title,
                    presentation = "opaque",
                    leading = content.back?.let { actionSpec(it, "icon") },
                    actions = content.actions.map { actionSpec(it, "text") },
                    background = content.background,
                    foreground = content.foreground,
                ),
                tab = null,
                suspended = !enabled,
                dimColor = null,
                dimDurationMs = 0,
                rtl = slot.layoutDirection == View.LAYOUT_DIRECTION_RTL,
                appearance = NativeChromeAppearanceSpec.parse(null),
            ),
        )
        if (renderer.parent == null) {
            fallback = existingBar
            fallbackVisibility = existingBar.visibility
            renderer.visibility = View.INVISIBLE
            try {
                slot.addView(renderer, FrameLayout.LayoutParams(-1, -2, Gravity.TOP))
            } catch (_: IllegalStateException) {
                hide()
                return false
            }
            val observer = slot.viewTreeObserver
            val ready = object : ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    if (pending !== this) return true
                    cancelPending()
                    if (!slot.isAttachedToWindow || fallback?.parent !== slot || renderer.parent !== slot ||
                        lifecycle.currentState != Lifecycle.State.RESUMED ||
                        renderer.toolbar.width <= 0 || renderer.toolbar.height <= 0
                    ) {
                        hide()
                        return true
                    }
                    fallback?.visibility = View.GONE
                    renderer.visibility = View.VISIBLE
                    showing = true
                    onVisibilityChanged(true)
                    // Let the new visibility settle before drawing this slot.
                    return false
                }
            }
            preDrawObserver = observer
            pending = ready
            observer.addOnPreDrawListener(ready)
        }
        return true
    }

    /** Bottom of the displayed toolbar in [reference]'s screen coordinate frame. */
    fun bottomIn(reference: View): Int? {
        val toolbar = renderer.toolbar
        if (!showing || !slot.isAttachedToWindow || renderer.parent !== slot || !toolbar.isShown || toolbar.height == 0 ||
            !reference.isAttachedToWindow || toolbar.windowToken != reference.windowToken
        ) return null
        val toolbarLocation = IntArray(2)
        val referenceLocation = IntArray(2)
        toolbar.getLocationOnScreen(toolbarLocation)
        reference.getLocationOnScreen(referenceLocation)
        return toolbarLocation[1] + toolbar.height - referenceLocation[1]
    }

    fun hide() {
        cancelPending()
        ownership.clear()
        active = false
        displayedContent = null
        displayedLayoutDirection = null
        renderer.toolbar.dismissPopupMenus()
        (renderer.parent as? FrameLayout)?.removeView(renderer)
        renderer.clear()
        fallback?.visibility = fallbackVisibility
        fallback = null
        if (showing) {
            showing = false
            onVisibilityChanged(false)
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        lifecycle.removeObserver(observer)
        slot.removeOnLayoutChangeListener(layout)
        slot.removeOnAttachStateChangeListener(attachment)
        hide()
    }

    private fun receive(method: String, args: Map<String, Any?>) {
        if (method != "event" || !showing || !active || !slot.isAttachedToWindow || renderer.parent !== slot ||
            lifecycle.currentState != Lifecycle.State.RESUMED ||
            !ownership.accepts(args["semanticRevision"] as? Int)
        ) return
        if (!slot.hasWindowFocus() && args["androidOverflow"] != true) return
        (args["actionId"] as? String)?.let(onAction)
    }

    private fun cancelPending() {
        val observer = preDrawObserver
        val listener = pending
        if (observer != null && observer.isAlive && listener != null) {
            observer.removeOnPreDrawListener(listener)
        }
        preDrawObserver = null
        pending = null
    }

    private fun updateLayoutDirection() {
        val direction = slot.layoutDirection
        renderer.layoutDirection = direction
        renderer.topContainer.layoutDirection = direction
        renderer.toolbar.layoutDirection = direction
        displayedLayoutDirection = direction
    }

    private fun actionSpec(action: Action, style: String) = NativeChromeActionSpec(
        id = action.id,
        label = action.label,
        icon = null,
        enabled = action.enabled,
        style = style,
        androidOverflowIfRoom = action.overflowIfRoom,
    )
}

internal class EmbeddedTopBarOwnership {
    private var generation = 0
    private var current: Int? = null

    fun replace(): Int = (++generation).also { current = it }

    fun clear() {
        current = null
    }

    fun accepts(generation: Int?): Boolean = current != null && current == generation
}
