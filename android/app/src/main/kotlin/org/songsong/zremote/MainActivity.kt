package org.songsong.zremote

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keep the latest deep-link intent so app_links / home_widget see it.
        setIntent(intent)
    }
}
