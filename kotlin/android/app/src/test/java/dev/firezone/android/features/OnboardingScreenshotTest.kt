// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features

import android.app.Application
import android.os.Bundle
import android.os.Looper
import androidx.appcompat.app.AppCompatActivity
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RobolectricDeviceQualifiers
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.roborazziSystemPropertyOutputDirectory
import dev.firezone.android.R
import dev.firezone.android.features.permission.certificate.ui.compose.CertificatePermissionScreen
import dev.firezone.android.features.permission.vpn.ui.VpnPermissionActivity
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.signin.ui.compose.SignInScreen
import dev.firezone.android.features.signin.ui.startSessionLabel
import dev.firezone.android.features.signin.ui.startSessionPrompt
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import uniffi.x509claims.Identity

// Renders the screens shown before a session starts to PNGs; `./gradlew recordRoborazziDebug` writes them.
//
// `NotificationPermissionActivity` only works on top of a Hilt graph, which a screenshot does not
// need, so the activity below hosts its layout instead. `VpnPermissionActivity` needs no graph,
// so it is rendered as it ships.
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(
    sdk = [34],
    application = Application::class,
    qualifiers = RobolectricDeviceQualifiers.Pixel5,
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

    // The email matches the certificate the X.509 settings captures show, so the gallery tells one story.
    @OptIn(ExperimentalRoborazziApi::class)
    @Test
    fun signInWithCertificate() {
        val identity = Identity.Claimed(email = "jane.doe@example.com")
        val application = RuntimeEnvironment.getApplication()

        captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/sign-in-certificate.png") {
            FirezoneTheme {
                SignInScreen(
                    onSignIn = {},
                    onSettings = {},
                    signInLabel = startSessionLabel(application, identity),
                    promptLabel = startSessionPrompt(application, identity),
                )
            }
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

    @Test
    fun vpnPermission() = capture("vpn-permission", VpnPermissionActivity::class.java)

    @Test
    fun notificationPermission() = capture("notification-permission", NotificationPermissionScreenshotActivity::class.java)

    @OptIn(ExperimentalRoborazziApi::class)
    private fun <A : AppCompatActivity> capture(
        name: String,
        activityClass: Class<A>,
    ) {
        val activity = Robolectric.buildActivity(activityClass).setup().get()
        shadowOf(Looper.getMainLooper()).idle()

        activity.window.decorView.captureRoboImage("${roborazziSystemPropertyOutputDirectory()}/$name.png")
    }
}

internal class NotificationPermissionScreenshotActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        setTheme(R.style.AppTheme_Base)
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_notification_permission)
    }
}
