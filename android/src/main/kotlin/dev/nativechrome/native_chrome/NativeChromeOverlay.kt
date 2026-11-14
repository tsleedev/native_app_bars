package dev.nativechrome.native_chrome

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.view.ContextThemeWrapper
import androidx.core.graphics.drawable.DrawableCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.android.material.appbar.MaterialToolbar
import com.google.android.material.badge.BadgeDrawable
import com.google.android.material.badge.BadgeUtils
import com.google.android.material.bottomnavigation.BottomNavigationView
import com.google.android.material.navigation.NavigationBarView
import com.google.android.material.navigationrail.NavigationRailView

/**
 * Native bars drawn as sibling views above the FlutterView inside the
 * Activity's content frame. The FlutterView is never re-parented. Touches
 * outside the bars fall through to Flutter; while suspended every touch falls
 * through so Flutter's modal barrier keeps working.
 */
@SuppressLint("ViewConstructor")
internal class NativeChromeOverlay(
    context: Context,
    private val send: (String, Map<String, Any?>) -> Unit,
    private val nextRequestId: () -> Int,
    private val icons: (NativeChromeIconSpec?) -> Bitmap?,
) : FrameLayout(context) {
    private val themed = ContextThemeWrapper(context, com.google.android.material.R.style.Theme_Material3_Light_NoActionBar)
    val topContainer = FrameLayout(themed)
    val toolbar = MaterialToolbar(themed)
    val bottomContainer = FrameLayout(themed)
    val bottomNav = BottomNavigationView(themed)
    /** Side rail used instead of [bottomNav] on large screens (opt-in, see [NativeChromeTabSpec.rail]). */
    val railContainer = FrameLayout(themed)
    val rail = NavigationRailView(themed)
    private val navs: List<NavigationBarView> = listOf(bottomNav, rail)
    private var railActive = false
    private val topDim = View(context)
    private val bottomDim = View(context)
    private val railDim = View(context)
    private val topIds = GenerationalMenuIds()
    private val badgeTasks = GenerationalTasks({ toolbar.post(it) }, { toolbar.removeCallbacks(it) })
    private val density = resources.displayMetrics.density

    private var state: NativeChromeStateSpec? = null
    private var appliedTop: NativeChromeTopSpec? = null
    private var appliedTopKey: Any? = null
    private var appliedTabItems: List<NativeChromeTabItemSpec>? = null
    private var appliedTabKey: Any? = null

    /** Bumped by the plugin when new icon bitmaps arrive. */
    var iconVersion = 0
    private var tabIds: List<String> = emptyList()
    private var applying = false
    private var insetTop = 0
    private var insetBottom = 0
    private var insetLeft = 0
    private var insetRight = 0
    private var lastGeometry: Map<String, Any>? = null
    private var snapshot: ImageView? = null
    private var snapshotOpacity = 1f
    private var transitionId: Int? = null
    private var dimAnimator: ValueAnimator? = null

    /** Number of native-side filtered inputs (diagnostics/tests). */
    var nativeFiltered = 0
        private set

    init {
        clipChildren = false
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        topContainer.addView(toolbar, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        bottomContainer.addView(bottomNav, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        addView(topContainer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.TOP))
        addView(bottomContainer, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.BOTTOM))
        railContainer.addView(rail, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(railContainer, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT, Gravity.TOP or Gravity.START))
        for (dim in listOf(topDim, bottomDim, railDim)) {
            dim.alpha = 0f
            dim.isClickable = false
            dim.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            // Solid top chrome and its dim share one opacity group. The
            // outgoing topContainer.draw(Canvas) includes the dim too.
            if (dim === topDim) topContainer.addView(dim, LayoutParams(0, 0))
            else addView(dim, LayoutParams(0, 0))
        }
        topContainer.visibility = View.INVISIBLE
        bottomContainer.visibility = View.INVISIBLE
        railContainer.visibility = View.GONE
        toolbar.tag = "native_chrome.topBar"
        bottomNav.tag = "native_chrome.tabBar"
        rail.tag = "native_chrome.tabRail"
        // Every tab label is always shown, as on iOS (UITabBar) and with the
        // Flutter renderer (NavigationBar). Material's default "auto" mode
        // shows only the selected label once there are four or more items.
        for (nav in navs) nav.labelVisibilityMode = NativeChromeTabStyle.LABEL_VISIBILITY
        // The container owns the system-bar padding; stop Material's own handling.
        ViewCompat.setOnApplyWindowInsetsListener(bottomNav) { _, insets -> insets }
        ViewCompat.setOnApplyWindowInsetsListener(rail) { _, insets -> insets }
        ViewCompat.setOnApplyWindowInsetsListener(toolbar) { _, insets -> insets }
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            recordInsets(insets)
            insets
        }
        for (nav in navs) {
            nav.setOnItemSelectedListener { item ->
                if (applying) true else {
                    request(item)
                    false // Request only: Dart decides and answers with a new state.
                }
            }
            nav.setOnItemReselectedListener { item -> if (!applying) request(item) }
        }
        toolbar.setOnMenuItemClickListener { item ->
            val top = state?.top
            val action = top?.actions?.getOrNull(topIds.index(item.itemId))
            if (top != null && action != null) emitTop(action, top.stamp)
            true
        }
        addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> publishGeometry() }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ViewCompat.getRootWindowInsets(this)?.let { recordInsets(it) }
        ViewCompat.requestApplyInsets(this)
    }

    private var rawInsets = IntArray(4)

    private fun recordInsets(insets: WindowInsetsCompat) {
        val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
        rawInsets = intArrayOf(bars.left, bars.top, bars.right, bars.bottom)
        applyEffectiveInsets()
    }

    /**
     * Window insets are relative to the window. When the content frame does not
     * extend under the system bars (for example API < 30 with 3-button
     * navigation), only the part that actually overlaps this view is applied.
     */
    private fun applyEffectiveInsets() {
        val root = rootView ?: return
        val loc = IntArray(2)
        getLocationInWindow(loc)
        val w = if (width > 0) width else root.width
        val h = if (height > 0) height else root.height
        val left = maxOf(0, rawInsets[0] - loc[0])
        val top = maxOf(0, rawInsets[1] - loc[1])
        val right = maxOf(0, rawInsets[2] - maxOf(0, root.width - (loc[0] + w)))
        val bottom = maxOf(0, rawInsets[3] - maxOf(0, root.height - (loc[1] + h)))
        if (top == insetTop && bottom == insetBottom && left == insetLeft && right == insetRight) return
        insetTop = top
        insetBottom = bottom
        insetLeft = left
        insetRight = right
        topContainer.setPadding(insetLeft, insetTop, insetRight, 0)
        bottomContainer.setPadding(insetLeft, 0, insetRight, insetBottom)
        updateRailPadding()
        post { requestLayout() }
    }

    private fun rtl() = layoutDirection == View.LAYOUT_DIRECTION_RTL

    /** The rail sits on the start edge, beside the start system inset. */
    private fun railStartInset() = if (rtl()) insetRight else insetLeft

    private fun updateRailPadding() {
        val start = railStartInset()
        railContainer.setPadding(if (rtl()) 0 else start, 0, if (rtl()) start else 0, insetBottom)
    }

    /** Below the top bar when one is shown, else below the status bar. */
    private fun railTop() =
        if (topContainer.visibility == View.VISIBLE) topContainer.measuredHeight else insetTop

    private fun railWidthPx() = railStartInset() + (RAIL_WIDTH_DP * density).toInt()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
        if (railContainer.visibility != View.GONE) {
            val height = maxOf(0, measuredHeight - railTop())
            railContainer.measure(
                MeasureSpec.makeMeasureSpec(railWidthPx(), MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
            )
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration?) {
        super.onConfigurationChanged(newConfig)
        // The rail follows the smallest screen width; resizing (multi-window,
        // foldables, configChanges-handled rotation) can cross 600dp.
        post {
            reapply()
            requestLayout()
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        ViewCompat.getRootWindowInsets(this)?.let { recordInsets(it) }
        if (railContainer.visibility != View.GONE) {
            val top = railTop()
            val w = railWidthPx()
            if (rtl()) railContainer.layout(width - w, top, width, height)
            else railContainer.layout(0, top, w, height)
        }
        topDim.layout(0, 0, topContainer.width, topContainer.height)
        bottomDim.layout(0, bottomContainer.top, width, height)
        railDim.layout(railContainer.left, railContainer.top, railContainer.right, railContainer.bottom)
        snapshot?.layout(topContainer.left, topContainer.top, topContainer.right, topContainer.bottom)
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (state?.suspended == true) return false
        return super.dispatchTouchEvent(ev)
    }

    fun geometry(): Map<String, Any> = mapOf(
        "hostInstalled" to true,
        "topInset" to insetTop / density.toDouble(),
        "topBarHeight" to toolbar.height / density.toDouble(),
        "topBarVisible" to (topContainer.visibility == View.VISIBLE),
        "tabBarHeight" to if (railActive) 0.0 else bottomContainer.height / density.toDouble(),
        "tabBarVisible" to if (railActive) railContainer.visibility == View.VISIBLE
            else bottomContainer.visibility == View.VISIBLE,
        // Optional fields (older Dart ignores them): where the tab bar is.
        "tabBarPlacement" to if (railActive) "start" else "bottom",
        "tabRailWidth" to if (railActive) railContainer.width / density.toDouble() else 0.0,
    )

    private fun publishGeometry() {
        if (toolbar.height == 0 && bottomContainer.height == 0 && railContainer.width == 0) return
        val current = geometry()
        if (current == lastGeometry) return
        lastGeometry = current
        send("geometry", current)
    }

    // ------------------------------------------------------------- state

    fun reapply() {
        state?.let { apply(it) }
    }

    /** Drops the connection's state: hides bars, ends transition and dim. */
    fun clear() {
        endTransition()
        dimAnimator?.cancel()
        state = null
        appliedTop = null
        appliedTopKey = null
        appliedTabItems = null
        detachTopBadges()
        topContainer.visibility = View.INVISIBLE
        bottomContainer.visibility = View.INVISIBLE
        railContainer.visibility = View.GONE
        railActive = false
        topContainer.alpha = 1f
        topDim.alpha = 0f
        bottomDim.alpha = 0f
        railDim.alpha = 0f
        topDim.visibility = View.INVISIBLE
        bottomDim.visibility = View.INVISIBLE
        railDim.visibility = View.INVISIBLE
        setAccessibilitySuspended(false)
        requestLayout()
        android.util.Log.d(TAG, "cleared")
    }

    fun apply(next: NativeChromeStateSpec) {
        val previous = state
        state = next
        layoutDirection = if (next.rtl) View.LAYOUT_DIRECTION_RTL else View.LAYOUT_DIRECTION_LTR
        updateRailPadding()
        topContainer.alpha = next.top?.opacity ?: 1f
        applyTop(next.top, next.appearance)
        applyTab(next.tab, next.appearance)
        applySuspension(next, previous)
        bringToFront()
    }

    private fun drawable(spec: NativeChromeIconSpec?, tint: Int?): Drawable? {
        val bitmap = icons(spec) ?: return null
        val d = BitmapDrawable(resources, bitmap).mutate()
        if (tint != null) DrawableCompat.setTint(d, tint)
        return d
    }

    private fun applyTop(top: NativeChromeTopSpec?, appearance: NativeChromeAppearanceSpec) {
        if (top == null || top.presentation == "hidden") {
            topContainer.visibility = View.INVISIBLE
            return
        }
        topContainer.visibility = View.VISIBLE
        // Rebuilding the menu replaces its views; doing that while a finger is
        // down loses the click. Only rebuild when this bar's content changed.
        val key = listOf(appearance, iconVersion)
        val old = appliedTop
        if (old != null && top.copy(opacity = old.opacity,
                stamp = top.stamp.copy(semanticRevision = old.stamp.semanticRevision)) == old
            && key == appliedTopKey) return
        appliedTop = top
        appliedTopKey = key
        val background = if (top.presentation == "transparent") 0 else (top.background ?: appearance.background)
        if (background != null) topContainer.setBackgroundColor(background)
        val foreground = top.foreground ?: appearance.foreground
        val leading = top.leading
        // An icon leading uses the toolbar's navigation button. Text, done and
        // loading leadings are custom views; the title then is a custom view
        // too so both keep their order (Toolbar lays out custom views after
        // its own title).
        val leadingIsIcon = leading != null && leading.style == "icon" && !leading.loading &&
            drawable(leading.icon, foreground) != null
        leadingView?.let { toolbar.removeView(it) }
        leadingView = null
        if (leading != null && leadingIsIcon) {
            toolbar.navigationIcon = drawable(leading.icon, foreground)
            toolbar.navigationContentDescription = leading.label
            toolbar.setNavigationOnClickListener { emitTop(leading, top.stamp) }
        } else {
            toolbar.navigationIcon = null
            toolbar.setNavigationOnClickListener(null)
        }
        customTitle?.let { toolbar.removeView(it) }
        customTitle = null
        if (leading != null && !leadingIsIcon) {
            val view = if (leading.loading) progress(leading.label, foreground)
            else actionText(leading, foreground) { emitTop(leading, top.stamp) }
            view.tag = "native_chrome.top.${leading.id}"
            val size = view.layoutParams
            toolbar.addView(view, androidx.appcompat.widget.Toolbar.LayoutParams(
                size?.width ?: android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                size?.height ?: android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.START or Gravity.CENTER_VERTICAL,
            ).apply {
                marginStart = (12 * density).toInt()
                // A spinner has no padding of its own; keep the title off it.
                if (leading.loading) marginEnd = (16 * density).toInt()
            })
            leadingView = view
        }
        applyTitle(top, foreground, forceCustom = leading != null && !leadingIsIcon)
        val menu = toolbar.menu
        detachTopBadges()
        menu.clear()
        topIds.next()
        top.actions.forEachIndexed { index, action ->
            val item = menu.add(Menu.NONE, topIds.id(index), index, styledLabel(action, foreground))
            if (action.style == "icon") drawable(action.icon, foreground)?.let { item.icon = it }
            item.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS)
            item.isEnabled = action.enabled
            item.contentDescription = action.label
            if (action.style == "icon" && !action.loading) action.badge?.let { attachTopBadge(item, it, action.label) }
            if (action.loading) {
                item.actionView = progress(action.label, foreground).apply {
                    val size = (24 * density).toInt()
                    val end = (12 * density).toInt()
                    layoutParams = android.view.ViewGroup.LayoutParams(size + end, size)
                    setPaddingRelative(0, 0, end, 0)
                }
            }
        }
    }

    private var leadingView: View? = null

    /** Label with the done weight and the bar's foreground (dimmed when disabled). */
    private fun styledLabel(action: NativeChromeActionSpec, foreground: Int?): CharSequence =
        android.text.SpannableString(action.label).apply {
            if (action.style == "done") {
                setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), 0, length, 0)
            }
            if (foreground != null) {
                val color = if (action.enabled) foreground
                else androidx.core.graphics.ColorUtils.setAlphaComponent(foreground, 0x61)
                setSpan(android.text.style.ForegroundColorSpan(color), 0, length, 0)
            }
        }

    private fun progress(label: String, foreground: Int?): View =
        android.widget.ProgressBar(themed).apply {
            isIndeterminate = true
            contentDescription = label
            foreground?.let { indeterminateTintList = ColorStateList.valueOf(it) }
            val size = (24 * density).toInt()
            layoutParams = android.view.ViewGroup.LayoutParams(size, size)
        }

    /** A text (or done) action as a touchable view, for the leading slot. */
    private fun actionText(action: NativeChromeActionSpec, foreground: Int?, onClick: () -> Unit): View =
        android.widget.TextView(themed).apply {
            text = styledLabel(action, foreground)
            textSize = 16f
            minHeight = (48 * density).toInt()
            minWidth = (48 * density).toInt()
            gravity = Gravity.CENTER
            setPadding((12 * density).toInt(), 0, (12 * density).toInt(), 0)
            contentDescription = action.label
            isClickable = true
            isFocusable = true
            isEnabled = action.enabled
            setOnClickListener { onClick() }
            announceAsButton(this)
        }

    private fun announceAsButton(view: View) {
        ViewCompat.setAccessibilityDelegate(view, object : androidx.core.view.AccessibilityDelegateCompat() {
            override fun onInitializeAccessibilityNodeInfo(
                host: View,
                info: androidx.core.view.accessibility.AccessibilityNodeInfoCompat,
            ) {
                super.onInitializeAccessibilityNodeInfo(host, info)
                info.className = android.widget.Button::class.java.name
            }
        })
    }

    private var customTitle: View? = null

    /**
     * Platform title, or a custom (tappable / expanded) title view. A title
     * action's icon (or a spinner while it is loading) follows a platform
     * title and precedes a start-aligned one, as on iOS and in Flutter.
     */
    private fun applyTitle(top: NativeChromeTopSpec, foreground: Int?, forceCustom: Boolean) {
        val custom = forceCustom || top.titleAction != null || top.titleAlignment == "expandedLeading"
        if (!custom) {
            toolbar.title = top.title
            if (foreground != null) toolbar.setTitleTextColor(foreground)
            return
        }
        toolbar.title = null
        val action = top.titleAction
        val text = android.widget.TextView(themed).apply {
            text = top.title
            textSize = if (top.titleAlignment == "expandedLeading") 22f else 20f
            foreground?.let { setTextColor(it) }
            importantForAccessibility = if (action != null) View.IMPORTANT_FOR_ACCESSIBILITY_NO
            else View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        val adornment: View? = when {
            action == null -> null
            action.loading -> progress(action.label, foreground).apply {
                importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            }
            else -> drawable(action.icon, foreground)?.let { d ->
                android.widget.ImageView(themed).apply {
                    setImageDrawable(d)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }
            }
        }
        val row = android.widget.LinearLayout(themed).apply {
            orientation = android.widget.LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = (48 * density).toInt()
            val gap = (6 * density).toInt()
            val after = top.titleAlignment == "platform"
            fun addAdornment() {
                adornment?.let {
                    val size = (20 * density).toInt()
                    val lp = android.widget.LinearLayout.LayoutParams(size, size)
                    if (after) lp.marginStart = gap else lp.marginEnd = gap
                    addView(it, lp)
                }
            }
            if (!after) addAdornment()
            addView(text)
            if (after) addAdornment()
            if (action != null) {
                contentDescription = action.label
                isClickable = true
                isFocusable = true
                isEnabled = action.enabled
                tag = "native_chrome.top.${action.id}"
                setOnClickListener { emitTop(action, top.stamp) }
                announceAsButton(this)
            }
        }
        toolbar.addView(row, androidx.appcompat.widget.Toolbar.LayoutParams(
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.START or Gravity.CENTER_VERTICAL,
        ))
        customTitle = row
    }

    private fun emitTop(action: NativeChromeActionSpec, stamp: NativeChromeOwnerStamp) {
        val event = NativeChromeFilter.topAction(state, action, stamp, transitionId != null)
        if (event == null) {
            nativeFiltered++
            android.util.Log.d(TAG, "filtered topAction ${action.id} suspended=${state?.suspended} transition=$transitionId")
            return
        }
        android.util.Log.d(TAG, "emit topAction ${action.id}")
        send("event", event + ("requestId" to nextRequestId()))
    }

    /** Badges of top bar icon actions attached to the current menu, by item id. */
    private val topBadges = HashMap<Int, BadgeDrawable>()

    /**
     * Attaches [badge] to [item] once the toolbar has laid out its view. The
     * work is cancelled when the menu is rebuilt or cleared (new generation),
     * and runs only while [item] is still this menu's item. Item ids are new
     * for every menu generation, so Material's own id lookup can never reach
     * a later item either.
     */
    @SuppressLint("UnsafeOptInUsageError")
    private fun attachTopBadge(item: MenuItem, badge: String, label: String) {
        val drawable = BadgeDrawable.create(themed)
        drawable.isVisible = true
        // BadgeUtils replaces the toolbar item's accessibility description with
        // the badge's own (a generic "N new notifications"). Keep the action
        // label, which carries the meaning (and the count), instead: the badge
        // shows the given text as is and describes itself with the label.
        if (badge.isEmpty()) {
            drawable.clearText()
            drawable.clearNumber()
            drawable.setContentDescriptionNumberless(label)
        } else {
            drawable.text = badge
            drawable.setContentDescriptionForText(label)
        }
        val itemId = item.itemId
        badgeTasks.schedule({ toolbar.menu.findItem(itemId) === item }) {
            topBadges[itemId] = drawable
            BadgeUtils.attachBadgeDrawable(drawable, toolbar, itemId)
        }
    }

    @SuppressLint("UnsafeOptInUsageError")
    private fun detachTopBadges() {
        badgeTasks.invalidate()
        topBadges.forEach { (itemId, drawable) -> BadgeUtils.detachBadgeDrawable(drawable, toolbar, itemId) }
        topBadges.clear()
    }

    private fun applyTab(tab: NativeChromeTabSpec?, appearance: NativeChromeAppearanceSpec) {
        if (tab == null || tab.hidden || tab.items.isEmpty()) {
            bottomContainer.visibility = View.INVISIBLE
            railContainer.visibility = View.GONE
            railActive = false
            return
        }
        // Large screens (smallest width >= 600dp): a side rail instead of the
        // bottom bar when the tab bar opts in. Only one of them is shown.
        railActive = tab.rail && resources.configuration.smallestScreenWidthDp >= RAIL_MIN_SMALLEST_WIDTH_DP
        bottomContainer.visibility = if (railActive) View.INVISIBLE else View.VISIBLE
        railContainer.visibility = if (railActive) View.VISIBLE else View.GONE
        appearance.background?.let {
            bottomContainer.setBackgroundColor(it)
            railContainer.setBackgroundColor(it)
            for (nav in navs) nav.setBackgroundColor(it)
        }
        val selectedColor = appearance.foreground ?: appearance.tint
        val unselected = appearance.unselected
        if (selectedColor != null && unselected != null) {
            val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
            val icon = ColorStateList(states, intArrayOf(selectedColor, unselected))
            for (nav in navs) {
                nav.itemIconTintList = icon
                nav.itemTextColor = icon
            }
        }
        appearance.indicator?.let { color ->
            for (nav in navs) nav.itemActiveIndicatorColor = ColorStateList.valueOf(color)
        }

        val ids = tab.items.map { it.id }
        applying = true
        try {
            if (ids != tabIds) {
                for (nav in navs) {
                    nav.menu.clear()
                    tab.items.forEachIndexed { index, spec -> nav.menu.add(Menu.NONE, index + 1, index, spec.label) }
                }
                tabIds = ids
                appliedTabItems = null
            }
            val previousItems = appliedTabItems
            val sameKey = appliedTabKey == iconVersion
            appliedTabItems = tab.items
            appliedTabKey = iconVersion
            tab.items.forEachIndexed { index, spec ->
                val previous = previousItems?.getOrNull(index)
                // Only touch views whose content changed (a badge update must not
                // recreate icons under the user's finger).
                val visualSame = sameKey && previous != null &&
                    previous.copy(badge = spec.badge, accessibilityValue = spec.accessibilityValue) == spec
                for (nav in navs) {
                    val item = nav.menu.findItem(index + 1) ?: continue
                    if (!visualSame || previous?.accessibilityValue != spec.accessibilityValue) {
                        item.contentDescription = spec.accessibilityValue?.let { "${spec.label}, $it" } ?: spec.label
                    }
                    if (!visualSame) {
                        item.title = spec.label
                        item.isEnabled = spec.enabled
                        val normal = drawable(spec.icon, null)
                        val selected = drawable(spec.selectedIcon ?: spec.icon, null)
                        if (normal != null && selected != null) {
                            item.icon = StateListDrawable().apply {
                                addState(intArrayOf(android.R.attr.state_checked), selected)
                                addState(intArrayOf(), normal)
                            }
                        }
                    }
                    if (previous?.badge == spec.badge && sameKey && previousItems != null) continue
                    val badge = spec.badge
                    if (badge == null) {
                        nav.removeBadge(index + 1)
                    } else {
                        val drawable = nav.getOrCreateBadge(index + 1)
                        drawable.isVisible = true
                        val number = badge.toIntOrNull()
                        when {
                            badge.isEmpty() -> drawable.clearNumber()
                            number != null -> drawable.number = number
                            else -> drawable.text = badge
                        }
                    }
                }
            }
            val index = ids.indexOf(tab.selectedId)
            if (index >= 0) {
                for (nav in navs) if (nav.selectedItemId != index + 1) nav.selectedItemId = index + 1
            }
        } finally {
            applying = false
        }
    }

    private fun request(item: MenuItem) {
        val id = tabIds.getOrNull(item.itemId - 1)
        val event = id?.let { NativeChromeFilter.tabRequest(state, it) }
        if (event == null) {
            nativeFiltered++
            android.util.Log.d(TAG, "filtered tabRequest $id suspended=${state?.suspended} tab=${state?.tab != null}")
            return
        }
        android.util.Log.d(TAG, "emit tabRequest $id")
        send("event", event + ("requestId" to nextRequestId()))
    }

    /**
     * While a popup suspends the bars they leave the accessibility tree (the
     * modal owns TalkBack focus); restored when the suspension ends or the
     * connection is cleared.
     */
    var accessibilitySuspended = false
        private set

    private fun setAccessibilitySuspended(hidden: Boolean) {
        accessibilitySuspended = hidden
        val mode = if (hidden) View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS else View.IMPORTANT_FOR_ACCESSIBILITY_AUTO
        topContainer.importantForAccessibility = mode
        bottomContainer.importantForAccessibility = mode
        railContainer.importantForAccessibility = mode
    }

    private fun applySuspension(next: NativeChromeStateSpec, previous: NativeChromeStateSpec?) {
        if (accessibilitySuspended != next.suspended) setAccessibilitySuspended(next.suspended)
        val wasDimmed = previous?.suspended == true && previous.dimColor != null
        val dimmed = next.suspended && next.dimColor != null
        next.dimColor?.let {
            topDim.setBackgroundColor(it)
            bottomDim.setBackgroundColor(it)
            railDim.setBackgroundColor(it)
        }
        // A transparent top bar shows Flutter content that the popup barrier
        // already dims: fade only the toolbar there (dim exactly once).
        val transparentTop = next.top?.presentation == "transparent"
        topDim.visibility = if (transparentTop) View.INVISIBLE else topContainer.visibility
        bottomDim.visibility = bottomContainer.visibility
        railDim.visibility = if (railContainer.visibility == View.VISIBLE) View.VISIBLE else View.INVISIBLE
        val factor = next.dimColor?.let { 1f - android.graphics.Color.alpha(it) / 255f } ?: 1f
        val topTo = if (dimmed && !transparentTop) 1f else 0f
        val bottomTo = if (dimmed) 1f else 0f
        val toolbarTo = if (dimmed && transparentTop) factor else 1f
        if (topDim.alpha != topTo || bottomDim.alpha != bottomTo || railDim.alpha != bottomTo || toolbar.alpha != toolbarTo) {
            dimAnimator?.cancel()
            val topFrom = topDim.alpha
            val bottomFrom = bottomDim.alpha
            val railFrom = railDim.alpha
            val toolbarFrom = toolbar.alpha
            val duration = if (dimmed) next.dimDurationMs else (previous?.dimDurationMs ?: 200L)
            dimAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
                this.duration = duration
                addUpdateListener {
                    val t = it.animatedValue as Float
                    topDim.alpha = topFrom + (topTo - topFrom) * t
                    bottomDim.alpha = bottomFrom + (bottomTo - bottomFrom) * t
                    railDim.alpha = railFrom + (bottomTo - railFrom) * t
                    toolbar.alpha = toolbarFrom + (toolbarTo - toolbarFrom) * t
                }
                start()
            }
        }
        if (wasDimmed && !dimmed && dimAnimator == null) toolbar.alpha = 1f
    }

    // -------------------------------------------------------- transitions

    fun transition(map: Map<*, *>) {
        val id = (map["id"] as? Number)?.toInt()
        val progress = ((map["progress"] as? Number)?.toFloat() ?: 0f).coerceIn(0f, 1f)
        when (map["phase"]) {
            "begin" -> {
                endTransition()
                if (topContainer.visibility != View.VISIBLE || topContainer.width == 0 || topContainer.height == 0) return
                val bitmap = Bitmap.createBitmap(topContainer.width, topContainer.height, Bitmap.Config.ARGB_8888)
                topContainer.draw(Canvas(bitmap))
                val image = ImageView(context).apply {
                    setImageBitmap(bitmap)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }
                addView(image, indexOfChild(topContainer) + 1, LayoutParams(topContainer.width, topContainer.height, Gravity.TOP))
                snapshot = image
                // draw(Canvas) does not apply the root View's alpha. The
                // toolbar's popup dim is already in the bitmap; bake only
                // the outgoing container opacity in the snapshot View.
                snapshotOpacity = topContainer.alpha
                transitionId = id
                image.alpha = snapshotOpacity * (1f - progress)
            }
            "update" -> if (id == transitionId) snapshot?.alpha = snapshotOpacity * (1f - progress)
            "end" -> if (id == transitionId) endTransition()
        }
    }

    private fun endTransition() {
        snapshot?.let { removeView(it) }
        snapshot = null
        snapshotOpacity = 1f
        transitionId = null
    }

    /** Debug view of the native state (instrumentation and diagnostics). */
    fun debugSnapshot(): Map<String, Any?> = mapOf(
        "topVisible" to (topContainer.visibility == View.VISIBLE),
        "title" to toolbar.title?.toString(),
        "tabVisible" to (bottomContainer.visibility == View.VISIBLE),
        "railVisible" to (railContainer.visibility == View.VISIBLE),
        "labelVisibility" to navs.map { it.labelVisibilityMode },
        "selectedTab" to tabIds.getOrNull(bottomNav.selectedItemId - 1),
        "nativeFiltered" to nativeFiltered,
    )

    private companion object {
        const val TAG = "NativeChrome"
        /** Use an 80dp start rail at a smallest screen width of 600dp or more. */
        const val RAIL_MIN_SMALLEST_WIDTH_DP = 600
        const val RAIL_WIDTH_DP = 80
    }
}
