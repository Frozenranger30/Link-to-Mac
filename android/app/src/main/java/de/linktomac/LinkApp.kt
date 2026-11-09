package de.linktomac

import android.app.Application

class LinkApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
    }
}
