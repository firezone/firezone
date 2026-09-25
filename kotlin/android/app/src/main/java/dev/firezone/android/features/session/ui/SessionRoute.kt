// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.IBinder
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.toggle
import dev.firezone.android.features.session.ui.compose.SessionScreen
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.TunnelService.Companion.State
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.collections.immutable.toImmutableList
import kotlinx.coroutines.flow.emptyFlow

@Composable
internal fun SessionRoute(
    onSessionEnded: () -> Unit,
    viewModel: SessionViewModel = hiltViewModel(),
) {
    val context = LocalContext.current
    val tunnelService = rememberTunnelService()

    val resourcesState by (tunnelService?.resourcesState ?: emptyFlow()).collectAsStateWithLifecycle(emptyList())
    val connectedDevicesState by (tunnelService?.connectedDevicesState ?: emptyFlow()).collectAsStateWithLifecycle(emptyList())
    val favorites by viewModel.favorites.collectAsStateWithLifecycle()
    val serviceStatus by (tunnelService?.serviceState ?: emptyFlow()).collectAsStateWithLifecycle<State?>(null)
    val actorName by (tunnelService?.actorNameState ?: emptyFlow()).collectAsStateWithLifecycle(null)

    // There is no session left to show once the tunnel is down, so hand back to the launch check
    // to say where the app belongs instead.
    LaunchedEffect(serviceStatus) {
        if (serviceStatus == State.DOWN) onSessionEnded()
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
                        ResourceUiModel(resource, internetState)
                    } else {
                        ResourceUiModel(resource, ResourceState.ENABLED)
                    }
                }.toImmutableList()
        }

    SessionScreen(
        actorName = actorName,
        resources = resources,
        connectedDevices = connectedDevicesState.toImmutableList(),
        favorites = favorites,
        onToggleInternet = {
            val newState = internetState.toggle()
            tunnelService?.internetResourceToggled(newState)
            internetState = tunnelService?.internetState() ?: newState
        },
        onAddFavorite = { id -> viewModel.addFavoriteResource(id) },
        onRemoveFavorite = { id -> viewModel.removeFavoriteResource(id) },
        onSettings = {
            context.startActivity(SettingsActivity.createIntent(context, isUserSignedIn = true))
        },
        onEndSession = {
            viewModel.clearToken()
            tunnelService?.disconnect()
        },
    )
}

/** The running tunnel, bound for as long as the session is on screen and `null` until it answers. */
@Composable
private fun rememberTunnelService(): TunnelService? {
    val context = LocalContext.current
    var service by remember { mutableStateOf<TunnelService?>(null) }

    DisposableEffect(context) {
        val connection =
            object : ServiceConnection {
                override fun onServiceConnected(
                    name: ComponentName?,
                    binder: IBinder?,
                ) {
                    service = (binder as TunnelService.LocalBinder).getService()
                }

                override fun onServiceDisconnected(name: ComponentName?) {
                    // The binding still exists (the system will try to reconnect), so only the
                    // stale binder is dropped.
                    service = null
                }
            }

        context.bindService(Intent(context, TunnelService::class.java), connection, Context.BIND_AUTO_CREATE)

        onDispose {
            context.unbindService(connection)
            service = null
        }
    }

    return service
}
