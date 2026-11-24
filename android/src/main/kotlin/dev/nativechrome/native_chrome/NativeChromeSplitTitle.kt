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
 * title action), followed by a separate accessory button, optionally after a
 * leading image button (for example an avatar). Each control has at least a
 * 48dp square hit area. Shared by the overlay toolbar and [NativeChromeActionBar].
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
        leading: Control? = null,
        leadingIcon: Drawable? = null,
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
            // A short title still keeps a square hit area.
            minWidth = minimum
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
        val leadingButton = leading?.let { control ->
            ImageButton(context).apply {
                tag = "native_chrome.top.${control.id}"
                setImageDrawable(leadingIcon)
                scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
                // A 32dp image (for example an avatar) in a 48dp target.
                val inset = (8 * density).toInt()
                setPadding(inset, inset, inset, inset)
                contentDescription = control.label
                isEnabled = control.enabled
                background = ripple(context, borderless = true)
                setOnClickListener { if (control.enabled) control.invoke() }
            }
        }
        return LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = minimum
            leadingButton?.let {
                addView(it, LinearLayout.LayoutParams(minimum, minimum).apply {
                    marginEnd = (8 * density).toInt()
                })
            }
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
