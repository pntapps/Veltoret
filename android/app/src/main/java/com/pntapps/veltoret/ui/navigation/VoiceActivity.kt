package com.pntapps.veltoret.ui.navigation

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.pntapps.veltoret.MainActivity
import com.pntapps.veltoret.VeltoretApp

/**
 * Receives "Hey Google, play … on Veltoret" and "search for … on Veltoret" ([VoiceRequests]), then brings
 * Veltoret to the front and closes. Sent to MainActivity directly, Android only brought an already open
 * Veltoret forward and never delivered the request.
 */
class VoiceActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        VoiceRequests.consume(intent, (application as VeltoretApp).container)
        startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }
}
