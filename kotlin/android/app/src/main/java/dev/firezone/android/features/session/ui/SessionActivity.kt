// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.toggle
import dev.firezone.android.features.session.ui.compose.FirezoneTheme
import dev.firezone.android.features.session.ui.compose.SessionScreen
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.collections.immutable.toImmutableList

@AndroidEntryPoint
class SessionActivity : AppCompatActivity() {
    private var tunnelService by mutableStateOf<TunnelService?>(null)
    private var serviceBound = false
    private val viewModel: SessionViewModel by viewModels()

    private val serviceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(
                name: ComponentName?,
                service: IBinder?,
            ) {
                val binder = service as TunnelService.LocalBinder
                tunnelService = binder.getService()

                tunnelService?.let {
                    it.setServiceStateMutableStateFlow(viewModel.getServiceStatusMutableStateFlow())
                    it.setResourcesMutableStateFlow(viewModel.getResourcesMutableStateFlow())
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                // The binding still exists (the system will try to reconnect), so leave
                // `serviceBound` untouched for onDestroy; just drop the stale binder.
                tunnelService = null
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val intent = Intent(this, TunnelService::class.java)
        // Track whether the bind was requested (not whether it has connected yet) so onDestroy
        // always unbinds, even if the Activity is destroyed before onServiceConnected fires.
        serviceBound = bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)

        setContent {
            FirezoneTheme {
                val resourcesState by viewModel.resourcesStateFlow.collectAsStateWithLifecycle()
                val favorites by viewModel.favorites.collectAsStateWithLifecycle()
                val serviceStatus by viewModel.serviceStatusStateFlow.collectAsStateWithLifecycle()

                // Finish if the tunnel service dies.
                LaunchedEffect(serviceStatus) {
                    if (serviceStatus == TunnelService.Companion.State.DOWN) finish()
                }

                var internetState by remember { mutableStateOf(ResourceState.UNSET) }

                // Keep the internet-resource state in sync with the service across (re)binds and
                // server-pushed resource updates; the toggle handler updates it directly for an
                // immediate refresh.
                LaunchedEffect(resourcesState, tunnelService) {
                    internetState = tunnelService?.internetState() ?: ResourceState.UNSET
                }

                val resources =
                    remember(resourcesState, internetState) {
                        resourcesState
                            .map { resource ->
                                if (resource.isInternetResource()) {
                                    ResourceViewModel(resource, internetState)
                                } else {
                                    ResourceViewModel(resource, ResourceState.ENABLED)
                                }
                            }.toImmutableList()
                    }

                val actorName = remember { viewModel.getActorName() }

                SessionScreen(
                    actorName = actorName,
                    resources = resources,
                    favorites = favorites,
                    onToggleInternet = {
                        val newState = internetState.toggle()
                        tunnelService?.internetResourceToggled(newState)
                        internetState = tunnelService?.internetState() ?: newState
                    },
                    onAddFavorite = { id -> viewModel.addFavoriteResource(id) },
                    onRemoveFavorite = { id -> viewModel.removeFavoriteResource(id) },
                    onSettings = {
                        val settings = Intent(this@SessionActivity, SettingsActivity::class.java)
                        settings.putExtra("isUserSignedIn", true)
                        startActivity(settings)
                    },
                    onSignOut = {
                        viewModel.clearToken()
                        viewModel.clearActorName()
                        tunnelService?.disconnect()
                    },
                )
            }
        }
    }

    override fun onDestroy() {
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
            tunnelService = null
        }

        super.onDestroy()
    }
}
