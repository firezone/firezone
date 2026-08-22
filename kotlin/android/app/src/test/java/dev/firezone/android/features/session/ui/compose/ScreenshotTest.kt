// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.app.Application
import androidx.compose.runtime.Composable
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.features.session.ui.ResourceUiModel
import dev.firezone.android.tunnel.model.ConnectedDevice
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

// Renders the app's screens to PNGs so their states can be reviewed without an emulator.
// `./gradlew recordRoborazziDebug` writes them; a plain unit-test run captures nothing.
//
// The real Application is Hilt-annotated and starts Sentry and Firebase, none of which a
// screenshot needs, so the plain framework Application stands in for it.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = RobolectricDeviceQualifiers.Pixel5,
)
class ScreenshotTest {
    @Test
    fun sessionScreen() = captureSessionScreen("session-screen")

    @Test
    fun sessionScreenWithFavorites() =
        captureSessionScreen(
            "session-screen-favorites",
            favorites = Favorites(hashSetOf("gitlab")),
        )

    // Signing in before the portal has sent any resources, which is also what an account
    // with nothing shared with it looks like.
    @Test
    fun sessionScreenWithoutResources() =
        captureSessionScreen(
            "session-screen-no-resources",
            resources = persistentListOf(),
            connectedDevices = persistentListOf(),
        )

    private fun captureSessionScreen(
        name: String,
        resources: ImmutableList<ResourceUiModel> = sampleResources,
        connectedDevices: ImmutableList<ConnectedDevice> = sampleConnectedDevices,
        favorites: Favorites = Favorites(HashSet()),
    ) = capture(name) {
        SessionScreen(
            actorName = "Jane Doe",
            resources = resources,
            connectedDevices = connectedDevices,
            favorites = favorites,
            onToggleInternet = {},
            onAddFavorite = {},
            onRemoveFavorite = {},
            onSettings = {},
            onSignOut = {},
        )
    }

    @OptIn(ExperimentalRoborazziApi::class)
    private fun capture(
        name: String,
        content: @Composable () -> Unit,
    ) = captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png") {
        FirezoneTheme(content)
    }
}
