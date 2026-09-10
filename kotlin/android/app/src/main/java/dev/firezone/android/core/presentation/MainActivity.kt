// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core.presentation

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.ui.AppNavHost
import dev.firezone.android.ui.theme.FirezoneTheme
import javax.inject.Inject

@AndroidEntryPoint
internal class MainActivity : AppCompatActivity() {
    @Inject
    internal lateinit var repository: Repository

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                AppNavHost(
                    onNotificationPermissionRequested = repository::setNotificationPermissionRequested,
                    onSignInLaunched = ::finish,
                )
            }
        }
    }
}
