// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.session.ui.compose

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.R
import dev.firezone.android.STORE_SCREENSHOT_QUALIFIERS
import dev.firezone.android.core.data.Favorites
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.features.session.ui.ResourceUiModel
import dev.firezone.android.tunnel.mockResources
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.ResourceType
import dev.firezone.android.tunnel.model.StatusEnum
import dev.firezone.android.tunnel.model.toModel
import kotlinx.collections.immutable.ImmutableList
import kotlinx.collections.immutable.persistentListOf
import kotlinx.collections.immutable.toImmutableList
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

// Renders the app's screens to PNGs; `./gradlew recordRoborazziDebug` writes them.
//
// The real Application is Hilt-annotated and starts Sentry and Firebase, none of which a
// screenshot needs, so the plain framework Application stands in for it.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = STORE_SCREENSHOT_QUALIFIERS,
)
class ScreenshotTest {
    // Only the captures that have to drive the UI compose through this rule: the sheets, the device
    // pool screens and the scrolled list.
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun sessionScreen() = capture("session-screen") { SessionScreenSample() }

    @Test
    fun sessionScreenWithFavorites() =
        capture("session-screen-favorites") {
            SessionScreenSample(favorites = Favorites(hashSetOf("0854dca1-2c5b-468a-be85-0eec2f02a211")))
        }

    // Signing in before the portal has sent any resources, or an account with nothing shared.
    @Test
    fun sessionScreenWithoutResources() =
        capture("session-screen-no-resources") {
            SessionScreenSample(resources = persistentListOf())
        }

    // Any row part-way down does; it is scrolled to by index rather than by swipe because a fling
    // settles wherever its momentum leaves it, and the capture has to come out the same each run.
    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun sessionScreenScrolled() {
        composeRule.setContent { FirezoneTheme { SessionScreenSample() } }
        // The screen resets the list to the top once its tab settles, so let that land first.
        composeRule.waitForIdle()
        composeRule.onNode(hasScrollToIndexAction()).performScrollToIndex(5)
        composeRule.waitForIdle()
        captureScreenRoboImage("${roborazziSystemPropertyOutputDirectory()}/session-screen-scrolled.png")
    }

    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun sessionScreenProfile() {
        composeRule.setContent { FirezoneTheme { SessionScreenSample() } }
        val profile = RuntimeEnvironment.getApplication().getString(R.string.profile)
        composeRule.onNodeWithContentDescription(profile).performClick()
        composeRule.waitForIdle()
        captureScreenRoboImage("${roborazziSystemPropertyOutputDirectory()}/session-screen-profile.png")
    }

    @Test
    fun resourceDetailsInternet() = captureAfterTapping("resource-details-internet", rowText = "Internet Resource")

    @Test
    fun resourceDetails() = captureAfterTapping("resource-details", rowText = "Engineering wiki")

    @Test
    fun devicePoolDetails() = captureAfterTapping("device-pool-details", rowText = "Lab hardware")

    @Test
    fun devicePoolDetailsEmpty() =
        capture("device-pool-details-empty") {
            DevicePoolScreen(pool = emptyDevicePool, onSelectDevice = {}, onBack = {})
        }

    @Test
    fun deviceDetails() = captureAfterTapping("device-details", rowText = "Lab hardware", thenText = "bench-controller-01.firezone.network")

    @OptIn(ExperimentalRoborazziApi::class)
    private fun capture(
        name: String,
        content: @Composable () -> Unit,
    ) = captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png") {
        FirezoneTheme(content)
    }

    // A `ModalBottomSheet` renders into a window of its own, which the main-window capture
    // above misses; photographing the whole screen composites the list, the scrim and the
    // sheet the way the live app draws them.
    @OptIn(ExperimentalRoborazziApi::class)
    private fun captureAfterTapping(
        name: String,
        rowText: String,
        thenText: String? = null,
    ) {
        composeRule.setContent { FirezoneTheme { SessionScreenSample() } }
        composeRule
            .onNode(hasScrollToIndexAction())
            .performScrollToNode(hasText(rowText, substring = true))
        composeRule.onNodeWithText(rowText, substring = true).performClick()
        composeRule.waitForIdle()
        thenText?.let {
            composeRule.onNodeWithText(it).performClick()
            composeRule.waitForIdle()
        }
        captureScreenRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
    }
}

@Composable
private fun SessionScreenSample(
    resources: ImmutableList<ResourceUiModel> = sampleResources,
    favorites: Favorites = Favorites(HashSet()),
) {
    SessionScreen(
        actorName = "Jane Doe",
        resources = resources,
        favorites = favorites,
        onToggleInternet = {},
        onAddFavorite = {},
        onRemoveFavorite = {},
        onSettings = {},
        onEndSession = {},
    )
}

// The deployment `MockFixtures` describes, converted the way the service converts a real one, so
// the galleries and the mock launch cannot drift apart.
private val sampleResources: ImmutableList<ResourceUiModel> =
    mockResources.map { ResourceUiModel(it.toModel(), ResourceState.ENABLED) }.toImmutableList()

private val emptyDevicePool =
    ResourceUiModel(
        Resource(
            type = ResourceType.DevicePool,
            id = "2f3e8a61-5b7d-4c09-9e14-6a8d0c2b7f53",
            address = null,
            addressDescription = null,
            sites = emptyList(),
            name = "Spare hardware",
            status = StatusEnum.UNKNOWN,
        ),
        ResourceState.ENABLED,
    )
