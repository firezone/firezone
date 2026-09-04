// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features

import android.app.Application
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.STORE_SCREENSHOT_QUALIFIERS
import dev.firezone.android.features.permission.certificate.ui.compose.CertificatePermissionScreen
import dev.firezone.android.features.permission.notification.ui.compose.NotificationPermissionScreen
import dev.firezone.android.features.permission.vpn.ui.compose.VpnPermissionScreen
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.signin.ui.compose.SignInScreen
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
    qualifiers = STORE_SCREENSHOT_QUALIFIERS,
)
class OnboardingScreenshotTest {
    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun signIn() =
        captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/sign-in.png") {
            FirezoneTheme {
                SignInScreen(
                    onSignIn = {},
                    onSettings = {},
                )
            }
        }

    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun certificatePermission() =
        captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/certificate-permission.png") {
            FirezoneTheme {
                CertificatePermissionScreen(
                    onSelectCertificate = {},
                    onSkip = {},
                )
            }
        }

    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun vpnPermission() =
        captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/vpn-permission.png") {
            FirezoneTheme {
                VpnPermissionScreen(onRequestPermission = {})
            }
        }

    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun notificationPermission() =
        captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/notification-permission.png") {
            FirezoneTheme {
                NotificationPermissionScreen(
                    onRequestPermission = {},
                    onSkip = {},
                )
            }
        }
}
