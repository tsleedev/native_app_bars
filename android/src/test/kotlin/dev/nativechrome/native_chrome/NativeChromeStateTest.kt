package dev.nativechrome.native_chrome

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class NativeChromeStateTest {
    private fun wire(
        suspended: Boolean = false,
        saveEnabled: Boolean = true,
        hidden: Boolean = false,
        lease: String = "L1",
        revision: Int = 3,
    ) = mapOf(
        "protocol" to 2,
        "lease" to lease,
        "stateRevision" to revision,
        "suspended" to suspended,
        "rtl" to false,
        "appearance" to mapOf("brightness" to "dark", "tint" to 0xFF00796BL),
        "dim" to mapOf("color" to 0x8A000000L, "durationMs" to 150),
        "top" to mapOf(
            "ownerToken" to 7, "routeSession" to 2, "semanticRevision" to 4,
            "title" to "Detail", "presentation" to "opaque",
            "leading" to mapOf("id" to "back", "label" to "Back", "enabled" to true, "icon" to mapOf("key" to "k/back")),
            "actions" to listOf(mapOf("id" to "save", "label" to "Save", "enabled" to saveEnabled)),
        ),
        "tab" to mapOf(
            "ownerToken" to 9, "routeSession" to 5, "semanticRevision" to 6,
            "selectedId" to "home", "hidden" to hidden,
            "items" to listOf(
                mapOf("id" to "home", "label" to "Home", "enabled" to true, "badge" to "3", "icon" to mapOf("key" to "k/h")),
                mapOf("id" to "off", "label" to "Off", "enabled" to false, "icon" to mapOf("key" to "k/o")),
            ),
        ),
    )

    @Test
    fun parsesProtocolOne() {
        val state = assertNotNull(NativeChromeStateSpec.parse(wire()))
        assertEquals(3, state.revision)
        assertEquals("Detail", state.top?.title)
        assertEquals("back", state.top?.leading?.id)
        assertEquals(NativeChromeOwnerStamp(9, 5, 6), state.tab?.stamp)
        assertEquals("3", state.tab?.items?.first()?.badge)
        assertEquals(true, state.appearance.dark)
        assertEquals(0xFF00796B.toInt(), state.appearance.tint)
        assertEquals(150L, state.dimDurationMs)
    }

    @Test
    fun topActionBadgeIsOptional() {
        val plain = assertNotNull(NativeChromeStateSpec.parse(wire()))
        assertNull(plain.top?.actions?.first()?.badge, "absent field shows no badge")
        val base = wire()
        val top = base["top"] as Map<*, *>
        val action = (top["actions"] as List<*>).first() as Map<*, *>
        val withBadge = base + ("top" to (top + ("actions" to listOf(action + ("badge" to "99+")))))
        val state = assertNotNull(NativeChromeStateSpec.parse(withBadge))
        assertEquals("99+", state.top?.actions?.first()?.badge)
    }

    @Test
    fun tabAccessibilityValueIsOptional() {
        val plain = assertNotNull(NativeChromeStateSpec.parse(wire()))
        assertNull(plain.tab?.items?.first()?.accessibilityValue, "absent field keeps the platform default")
        val base = wire()
        val tab = base["tab"] as Map<*, *>
        val items = (tab["items"] as List<*>).map { it as Map<*, *> }
        val withValue = base + ("tab" to (tab + ("items" to listOf(items[0] + ("accessibilityValue" to "1000개"), items[1]))))
        val state = assertNotNull(NativeChromeStateSpec.parse(withValue))
        assertEquals("1000개", state.tab?.items?.first()?.accessibilityValue)
        assertEquals("3", state.tab?.items?.first()?.badge)
    }

    @Test
    fun topOpacityNormalizesAndKeepsTheDefault() {
        val base = wire()
        val top = base["top"] as Map<*, *>
        assertEquals(1f, NativeChromeStateSpec.parse(base)?.top?.opacity)
        for ((input, expected) in listOf(0.5 to 0.5f, 0.0 to 0f, -1.0 to 0f, 2.0 to 1f, Double.NaN to 1f, Double.POSITIVE_INFINITY to 1f, -1e100 to 0f, 1e100 to 1f, Double.NEGATIVE_INFINITY to 1f)) {
            val parsed = assertNotNull(NativeChromeStateSpec.parse(base + ("top" to (top + ("opacity" to input)))))
            assertEquals(expected, parsed.top?.opacity)
        }
    }

    @Test
    fun rejectsOtherProtocols() {
        assertNull(NativeChromeStateSpec.parse(mapOf("protocol" to 1, "lease" to "L1")))
        assertNull(NativeChromeStateSpec.parse(mapOf("protocol" to 2)), "lease required")
        assertNull(NativeChromeStateSpec.parse(null))
    }

    @Test
    fun tabRequestCarriesStampAndIsRequestOnly() {
        val state = NativeChromeStateSpec.parse(wire())
        val event = assertNotNull(NativeChromeFilter.tabRequest(state, "home"))
        assertEquals("tabRequest", event["type"])
        assertEquals("L1", event["lease"])
        assertEquals(9, event["ownerToken"])
        assertEquals(5, event["routeSession"])
        assertNull(NativeChromeFilter.tabRequest(state, "off"), "disabled item filtered")
        assertNull(NativeChromeFilter.tabRequest(state, "missing"))
        assertNull(NativeChromeFilter.tabRequest(NativeChromeStateSpec.parse(wire(suspended = true)), "home"))
        assertNull(NativeChromeFilter.tabRequest(NativeChromeStateSpec.parse(wire(hidden = true)), "home"))
    }

    @Test
    fun topActionFiltersStaleOwnerTransitionAndDisabled() {
        val state = NativeChromeStateSpec.parse(wire())!!
        val save = state.top!!.actions.first()
        assertNotNull(NativeChromeFilter.topAction(state, save, state.top!!.stamp, transitioning = false))
        assertNull(NativeChromeFilter.topAction(state, save, state.top!!.stamp, transitioning = true))
        assertNull(NativeChromeFilter.topAction(state, save, NativeChromeOwnerStamp(1, 1, 1), transitioning = false))
        val disabled = NativeChromeStateSpec.parse(wire(saveEnabled = false))!!
        assertNull(NativeChromeFilter.topAction(disabled, disabled.top!!.actions.first(), disabled.top!!.stamp, false))
    }

    @Test
    fun newLeaseDropsOldStateAndAcceptsLowRevision() {
        val c = NativeChromeConnection()
        assertEquals(true, c.attach("A"))
        assertEquals(true, c.accept(NativeChromeStateSpec.parse(wire(lease = "A", revision = 10))!!))
        assertEquals(false, c.accept(NativeChromeStateSpec.parse(wire(lease = "A", revision = 9))!!), "older revision in lease")
        assertEquals(1, c.nextRequestId())
        assertEquals(2, c.nextRequestId())
        assertEquals(true, c.attach("B"))
        assertNull(c.lastState, "previous connection state dropped")
        assertEquals(1, c.nextRequestId(), "request ids are per lease")
        assertEquals(true, c.accept(NativeChromeStateSpec.parse(wire(lease = "B", revision = 1))!!), "revision 1 of new lease")
        assertEquals(false, c.accept(NativeChromeStateSpec.parse(wire(lease = "A", revision = 99))!!), "late update of old lease")
        assertEquals(false, c.attach("B"), "same lease is not a new connection")
    }

    @Test
    fun staleDetachIsIgnored() {
        val c = NativeChromeConnection()
        c.attach("A")
        c.attach("B")
        c.accept(NativeChromeStateSpec.parse(wire(lease = "B", revision = 1))!!)
        assertEquals(false, c.detach("A"))
        assertNotNull(c.lastState)
        assertEquals(true, c.detach("B"))
        assertNull(c.lease)
        assertNull(c.lastState)
    }
}
