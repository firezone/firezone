// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import dev.firezone.android.core.data.Favorites

// Debug-only harness that renders the real SessionScreen against the shared sample data, so the
// connected-devices UI can be launched and poked on a device without a live tunnel. Registered as a
// separate launcher entry in the debug manifest; it never ships in release builds.
class SampleSessionActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                SessionScreen(
                    actorName = "Jane Doe",
                    resources = sampleResources,
                    connectedDevices = sampleConnectedDevices,
                    favorites = Favorites(HashSet()),
                    onToggleInternet = {},
                    onAddFavorite = {},
                    onRemoveFavorite = {},
                    onSettings = ::finish,
                    onSignOut = ::finish,
                )
            }
        }
    }
}
