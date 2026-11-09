package de.linktomac.features

import android.content.Context
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.os.Build
import android.util.DisplayMetrics
import android.view.Display
import android.view.WindowManager

/** Real (physical) size of the default display in its current rotation. */
object DisplayInfo {
    fun realSize(context: Context): Point {
        if (Build.VERSION.SDK_INT >= 30) {
            val wm = context.getSystemService(WindowManager::class.java)
            val b = wm.maximumWindowMetrics.bounds
            return Point(b.width(), b.height())
        }
        val dm = context.getSystemService(DisplayManager::class.java)
        val display = dm.getDisplay(Display.DEFAULT_DISPLAY)
        val p = Point()
        @Suppress("DEPRECATION")
        display.getRealSize(p)
        return p
    }

    fun densityDpi(context: Context): Int {
        val m: DisplayMetrics = context.resources.displayMetrics
        return m.densityDpi
    }
}
