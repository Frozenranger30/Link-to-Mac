package de.linktomac.features

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import de.linktomac.net.InputKey
import de.linktomac.net.InputScroll
import de.linktomac.net.InputTouch

/**
 * Accessibility service that injects taps, swipes and text coming from the mirror window on
 * the Mac (F9). The user has to enable it manually in the system settings.
 */
class InputService : AccessibilityService() {

    override fun onServiceConnected() {
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    private fun px(x: Double, y: Double): Pair<Float, Float> {
        val size = DisplayInfo.realSize(this)
        val fx = (x.coerceIn(0.0, 1.0) * (size.x - 1)).toFloat()
        val fy = (y.coerceIn(0.0, 1.0) * (size.y - 1)).toFloat()
        return fx to fy
    }

    fun touch(t: InputTouch) {
        val (x1, y1) = px(t.x, t.y)
        val path = Path().apply { moveTo(x1, y1) }
        val duration = when (t.action) {
            "tap" -> 40L
            "longpress" -> t.durationMs ?: 700L
            "swipe" -> {
                val (x2, y2) = px(t.x2 ?: t.x, t.y2 ?: t.y)
                path.lineTo(x2, y2)
                (t.durationMs ?: 250L).coerceIn(50L, 3000L)
            }
            else -> return
        }
        dispatch(path, duration)
    }

    fun scroll(s: InputScroll) {
        // A scroll is a short swipe in the opposite direction of the content movement.
        val (x1, y1) = px(s.x, s.y)
        val size = DisplayInfo.realSize(this)
        val x2 = (x1 - (s.dx * size.x).toFloat()).coerceIn(0f, size.x - 1f)
        val y2 = (y1 - (s.dy * size.y).toFloat()).coerceIn(0f, size.y - 1f)
        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        dispatch(path, 120)
    }

    private fun dispatch(path: Path, duration: Long) {
        val stroke = GestureDescription.StrokeDescription(path, 0, duration.coerceAtLeast(1))
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    fun key(k: InputKey) {
        when (k.key) {
            "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            "text" -> k.text?.let { editText { old -> old + it } }
            "backspace" -> editText { old -> if (old.isEmpty()) old else old.dropLast(1) }
            "enter" -> {
                val node = focused() ?: return
                if (Build.VERSION.SDK_INT >= 30) {
                    node.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
                } else {
                    editText { old -> old + "\n" }
                }
            }
        }
    }

    private fun focused(): AccessibilityNodeInfo? = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun editText(transform: (String) -> String) {
        val node = focused() ?: return
        if (!node.isEditable) return
        // Placeholder hint text is reported as text when the field is empty.
        val current = if (node.isShowingHintText) "" else node.text?.toString() ?: ""
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, transform(current))
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    companion object {
        @Volatile var instance: InputService? = null
            private set
    }
}
