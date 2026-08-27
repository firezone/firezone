// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import dev.firezone.android.core.data.Favorites

// Debug-only harness that renders the real SessionScreen against the shared sample data, so the
// connected-devices UI can be launched and poked on a device without a live tunnel. Registered as a
// separate launcher entry in the debug manifest; it never ships in release builds.
class SampleSessionActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                // Local in-memory favourites so the star toggles live in the harness; a fresh
                // Favorites instance per change mirrors how the real Repository emits, which is what
                // SessionScreen's identity-keyed recomposition relies on.
                var favorites by remember { mutableStateOf(Favorites(HashSet())) }

                SessionScreen(
                    actorName = "Jane Doe",
                    resources = sampleResources,
                    connectedDevices = sampleConnectedDevices,
                    favorites = favorites,
                    onToggleInternet = {},
                    onAddFavorite = { id -> favorites = Favorites(HashSet(favorites.inner).apply { add(id) }) },
                    onRemoveFavorite = { id -> favorites = Favorites(HashSet(favorites.inner).apply { remove(id) }) },
                    onSettings = ::finish,
                    onSignOut = ::finish,
                )
            }
        }
    }
}
