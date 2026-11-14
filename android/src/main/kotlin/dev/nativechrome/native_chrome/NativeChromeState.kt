package dev.nativechrome.native_chrome

/**
 * Wire model for the `update` message (protocol 1). Pure Kotlin so it can be
 * unit tested on the JVM.
 */
data class NativeChromeIconSpec(val key: String, val iosSymbol: String?) {
    companion object {
        fun parse(value: Any?): NativeChromeIconSpec? {
            val map = value as? Map<*, *> ?: return null
            val key = map["key"] as? String ?: return null
            return NativeChromeIconSpec(key, map["iosSymbol"] as? String)
        }
    }
}

data class NativeChromeActionSpec(
    val id: String,
    val label: String,
    val icon: NativeChromeIconSpec?,
    val enabled: Boolean,
    val loading: Boolean = false,
    /** icon | text | done */
    val style: String = "icon",
    /** Optional badge on an icon action: "" dot, number or short text. */
    val badge: String? = null,
) {
    companion object {
        fun parse(value: Any?): NativeChromeActionSpec? {
            val map = value as? Map<*, *> ?: return null
            val id = map["id"] as? String ?: return null
            return NativeChromeActionSpec(
                id = id,
                label = map["label"] as? String ?: id,
                icon = NativeChromeIconSpec.parse(map["icon"]),
                enabled = map["enabled"] as? Boolean ?: false,
                loading = map["loading"] as? Boolean ?: false,
                style = map["style"] as? String ?: "icon",
                badge = map["badge"] as? String,
            )
        }
    }
}

/** Identity echoed back with every native event. */
data class NativeChromeOwnerStamp(val ownerToken: Int, val routeSession: Int, val semanticRevision: Int) {
    fun wire(): MutableMap<String, Any?> = mutableMapOf(
        "ownerToken" to ownerToken,
        "routeSession" to routeSession,
        "semanticRevision" to semanticRevision,
    )

    companion object {
        fun parse(map: Map<*, *>): NativeChromeOwnerStamp? {
            val token = (map["ownerToken"] as? Number)?.toInt() ?: return null
            val session = (map["routeSession"] as? Number)?.toInt() ?: return null
            return NativeChromeOwnerStamp(token, session, (map["semanticRevision"] as? Number)?.toInt() ?: 0)
        }
    }
}

data class NativeChromeTopSpec(
    val stamp: NativeChromeOwnerStamp,
    val title: String,
    val presentation: String,
    val leading: NativeChromeActionSpec?,
    val actions: List<NativeChromeActionSpec>,
    /** platform | leading | expandedLeading */
    val titleAlignment: String = "platform",
    val titleAction: NativeChromeActionSpec? = null,
    val background: Int? = null,
    val foreground: Int? = null,
    val opacity: Float = 1f,
) {
    companion object {
        fun parse(value: Any?): NativeChromeTopSpec? {
            val map = value as? Map<*, *> ?: return null
            val stamp = NativeChromeOwnerStamp.parse(map) ?: return null
            return NativeChromeTopSpec(
                stamp = stamp,
                title = map["title"] as? String ?: "",
                presentation = map["presentation"] as? String ?: "opaque",
                leading = NativeChromeActionSpec.parse(map["leading"]),
                actions = (map["actions"] as? List<*> ?: emptyList<Any>()).mapNotNull { NativeChromeActionSpec.parse(it) },
                titleAlignment = map["titleAlignment"] as? String ?: "platform",
                titleAction = NativeChromeActionSpec.parse(map["titleAction"]),
                background = NativeChromeAppearanceSpec.color(map["background"]),
                foreground = NativeChromeAppearanceSpec.color(map["foreground"]),
                opacity = (map["opacity"] as? Number)?.toDouble()?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)?.toFloat() ?: 1f,
            )
        }
    }
}

data class NativeChromeTabItemSpec(
    val id: String,
    val label: String,
    val icon: NativeChromeIconSpec?,
    val selectedIcon: NativeChromeIconSpec?,
    val badge: String?,
    val enabled: Boolean,
    /** Optional accessibility value (null: platform default from the badge). */
    val accessibilityValue: String? = null,
) {
    companion object {
        fun parse(value: Any?): NativeChromeTabItemSpec? {
            val map = value as? Map<*, *> ?: return null
            val id = map["id"] as? String ?: return null
            return NativeChromeTabItemSpec(
                id = id,
                label = map["label"] as? String ?: id,
                icon = NativeChromeIconSpec.parse(map["icon"]),
                selectedIcon = NativeChromeIconSpec.parse(map["selectedIcon"]),
                badge = map["badge"] as? String,
                enabled = map["enabled"] as? Boolean ?: true,
                accessibilityValue = map["accessibilityValue"] as? String,
            )
        }
    }
}

data class NativeChromeTabSpec(
    val stamp: NativeChromeOwnerStamp,
    val items: List<NativeChromeTabItemSpec>,
    val selectedId: String,
    val hidden: Boolean,
    /** Opt-in: a side rail instead of the bottom bar on large screens (smallest width >= 600dp). */
    val rail: Boolean = false,
) {
    companion object {
        fun parse(value: Any?): NativeChromeTabSpec? {
            val map = value as? Map<*, *> ?: return null
            val stamp = NativeChromeOwnerStamp.parse(map) ?: return null
            return NativeChromeTabSpec(
                stamp = stamp,
                items = (map["items"] as? List<*> ?: emptyList<Any>()).mapNotNull { NativeChromeTabItemSpec.parse(it) },
                selectedId = map["selectedId"] as? String ?: "",
                hidden = map["hidden"] as? Boolean ?: false,
                rail = map["rail"] as? Boolean ?: false,
            )
        }
    }
}

data class NativeChromeAppearanceSpec(
    val dark: Boolean,
    val background: Int?,
    val foreground: Int?,
    val tint: Int?,
    val unselected: Int?,
    val indicator: Int?,
) {
    companion object {
        fun color(value: Any?): Int? = (value as? Number)?.toLong()?.toInt()

        fun parse(value: Any?): NativeChromeAppearanceSpec {
            val map = value as? Map<*, *> ?: emptyMap<Any, Any>()
            return NativeChromeAppearanceSpec(
                dark = map["brightness"] == "dark",
                background = color(map["background"]),
                foreground = color(map["foreground"]),
                tint = color(map["tint"]),
                unselected = color(map["unselected"]),
                indicator = color(map["indicator"]),
            )
        }
    }
}

data class NativeChromeStateSpec(
    /** Connection lease (protocol 2). Revisions are only compared within it. */
    val lease: String,
    val revision: Int,
    val top: NativeChromeTopSpec?,
    val tab: NativeChromeTabSpec?,
    val suspended: Boolean,
    val dimColor: Int?,
    val dimDurationMs: Long,
    val rtl: Boolean,
    val appearance: NativeChromeAppearanceSpec,
) {
    companion object {
        fun parse(value: Any?): NativeChromeStateSpec? {
            val map = value as? Map<*, *> ?: return null
            if ((map["protocol"] as? Number)?.toInt() != 2) return null
            val lease = map["lease"] as? String ?: return null
            val dim = map["dim"] as? Map<*, *>
            return NativeChromeStateSpec(
                lease = lease,
                revision = (map["stateRevision"] as? Number)?.toInt() ?: 0,
                top = NativeChromeTopSpec.parse(map["top"]),
                tab = NativeChromeTabSpec.parse(map["tab"]),
                suspended = map["suspended"] as? Boolean ?: false,
                dimColor = NativeChromeAppearanceSpec.color(dim?.get("color")),
                dimDurationMs = (dim?.get("durationMs") as? Number)?.toLong() ?: 0L,
                rtl = map["rtl"] as? Boolean ?: false,
                appearance = NativeChromeAppearanceSpec.parse(map["appearance"]),
            )
        }
    }
}

/**
 * Native first-line filter shared by the views. Dart remains the final
 * authority; this only avoids sending events the native side already knows are
 * invalid. It never drops input because an update is pending.
 */
object NativeChromeFilter {
    fun tabRequest(state: NativeChromeStateSpec?, tabId: String): Map<String, Any?>? {
        val tab = state?.tab ?: return null
        if (state.suspended || tab.hidden) return null
        val item = tab.items.firstOrNull { it.id == tabId } ?: return null
        if (!item.enabled) return null
        return tab.stamp.wire().apply {
            put("type", "tabRequest")
            put("tabId", tabId)
            put("lease", state.lease)
        }
    }

    fun topAction(
        state: NativeChromeStateSpec?,
        action: NativeChromeActionSpec,
        stamp: NativeChromeOwnerStamp,
        transitioning: Boolean,
    ): Map<String, Any?>? {
        val top = state?.top ?: return null
        if (state.suspended || transitioning || !action.enabled) return null
        if (top.stamp.ownerToken != stamp.ownerToken) return null
        return stamp.wire().apply {
            put("type", "topAction")
            put("actionId", action.id)
            put("lease", state.lease)
        }
    }
}

/**
 * Connection bookkeeping for one engine: the current lease, the last state of
 * that lease and its request ids. A new lease drops everything of the previous
 * one; a detach for any other lease is ignored.
 */
class NativeChromeConnection {
    var lease: String? = null
        private set
    var lastState: NativeChromeStateSpec? = null
        private set
    private var requestCounter = 0

    /** Returns true when [lease] replaced a different connection (or none). */
    fun attach(lease: String): Boolean {
        if (lease == this.lease) return false
        this.lease = lease
        lastState = null
        requestCounter = 0
        return true
    }

    /** Returns true when [lease] was current and is now closed. */
    fun detach(lease: String): Boolean {
        if (lease != this.lease) return false
        this.lease = null
        lastState = null
        requestCounter = 0
        return true
    }

    /** The activity's views are gone. Keep the lease and monotonic request IDs. */
    fun clearHostState() {
        lastState = null
    }

    /** Accepts [state] if it belongs to the current lease and is not older. */
    fun accept(state: NativeChromeStateSpec): Boolean {
        if (state.lease != lease) return false
        val current = lastState
        if (current != null && current.lease == state.lease && state.revision < current.revision) return false
        lastState = state
        return true
    }

    fun nextRequestId(): Int {
        requestCounter += 1
        return requestCounter
    }
}

/** Tab bar styling shared by the bottom bar and the side rail. */
internal object NativeChromeTabStyle {
    /** All labels always visible (Material's default hides unselected ones with 4+ items). */
    const val LABEL_VISIBILITY = com.google.android.material.navigation.NavigationBarView.LABEL_VISIBILITY_LABELED
}
