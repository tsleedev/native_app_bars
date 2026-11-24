package dev.nativechrome.native_chrome

import android.content.Context
import android.graphics.drawable.Drawable
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.view.AccessibilityDelegateCompat
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat

/**
 * Opt-in split title (`NativeTopBar.titleAccessory`): a one-line title that is
 * truncated at the end to the width the bar leaves (a button when it has a
 * title action), followed by a separate accessory button. Each control has at
 * least a 48dp hit area. Shared by the overlay toolbar and [NativeChromeActionBar].
 */
object NativeChromeSplitTitle {
    data class Control(
        val id: String,
        val label: String,
        val enabled: Boolean,
        val invoke: () -> Unit,
    )

    fun build(
        context: Context,
        title: String,
        textSize: Float,
        foreground: Int?,
        titleAction: Control?,
        accessory: Control,
        accessoryIcon: Drawable?,
    ): LinearLayout {
        val density = context.resources.displayMetrics.density
        val minimum = (48 * density).toInt()
        val text = TextView(context).apply {
            this.text = title
            this.textSize = textSize
            foreground?.let { setTextColor(it) }
            maxLines = 1
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_VERTICAL
            minHeight = minimum
            if (titleAction == null) {
                ViewCompat.setAccessibilityHeading(this, true)
            } else {
                tag = "native_chrome.top.${titleAction.id}"
                contentDescription = titleAction.label
                isClickable = true
                isFocusable = true
                isEnabled = titleAction.enabled
                background = ripple(context)
                setOnClickListener { if (titleAction.enabled) titleAction.invoke() }
                announceAsButton(this)
            }
        }
        val button = ImageButton(context).apply {
            tag = "native_chrome.top.${accessory.id}"
            setImageDrawable(accessoryIcon)
            scaleType = android.widget.ImageView.ScaleType.CENTER
            contentDescription = accessory.label
            isEnabled = accessory.enabled
            background = ripple(context, borderless = true)
            minimumWidth = minimum
            minimumHeight = minimum
            setPadding(0, 0, 0, 0)
            setOnClickListener { if (accessory.enabled) accessory.invoke() }
        }
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = minimum
            // A weighted wrap-content title shrinks (and ellipsizes) when the
            // bar is narrower than title + accessory.
            addView(text, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT, 1f,
            ))
            addView(button, LinearLayout.LayoutParams(minimum, minimum))
        }
    }

    private fun ripple(context: Context, borderless: Boolean = false): Drawable? {
        val value = TypedValue()
        val attr = if (borderless) android.R.attr.selectableItemBackgroundBorderless
        else android.R.attr.selectableItemBackground
        if (!context.theme.resolveAttribute(attr, value, true) || value.resourceId == 0) return null
        return context.getDrawable(value.resourceId)
    }

    private fun announceAsButton(view: View) {
        ViewCompat.setAccessibilityDelegate(view, object : AccessibilityDelegateCompat() {
            override fun onInitializeAccessibilityNodeInfo(host: View, info: AccessibilityNodeInfoCompat) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = android.widget.Button::class.java.name
            }
        })
    }
}
