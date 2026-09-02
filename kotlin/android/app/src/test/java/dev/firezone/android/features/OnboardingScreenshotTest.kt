// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features

import android.app.Application
import androidx.compose.runtime.Composable
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.features.permission.ui.compose.CertificatePermissionScreen
import dev.firezone.android.features.permission.ui.compose.NotificationPermissionScreen
import dev.firezone.android.features.permission.ui.compose.VpnPermissionScreen
import dev.firezone.android.features.signin.ui.compose.SignInScreen
import dev.firezone.android.features.splash.ui.compose.SplashScreen
import dev.firezone.android.ui.theme.FirezoneTheme
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

// Renders the screens shown before a session starts to PNGs; `./gradlew recordRoborazziDebug` writes them.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = RobolectricDeviceQualifiers.Pixel5,
)
class OnboardingScreenshotTest {
    @Test
    fun splash() = capture("splash") { SplashScreen() }

    @Test
    fun signIn() = capture("sign-in") { SignInScreen(onSignIn = {}, onSettings = {}) }

    @Test
    fun vpnPermission() = capture("vpn-permission") { VpnPermissionScreen(onRequestPermission = {}) }

    @Test
    fun notificationPermission() =
        capture("notification-permission") {
            NotificationPermissionScreen(onRequestPermission = {}, onSkip = {})
        }

    @Test
    fun certificatePermission() =
        capture("certificate-permission") {
            CertificatePermissionScreen(onSelectCertificate = {}, onSkip = {})
        }

    @OptIn(ExperimentalRoborazziApi::class)
    private fun capture(
        name: String,
        content: @Composable () -> Unit,
    ) = captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png") {
        FirezoneTheme(content)
    }
}
