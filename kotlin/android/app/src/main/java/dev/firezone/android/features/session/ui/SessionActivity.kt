/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.databinding.ActivitySessionBinding
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.TunnelService

@AndroidEntryPoint
internal class SessionActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySessionBinding
    private var tunnelService: TunnelService? = null
    private var serviceBound = false
    private val viewModel: SessionViewModel by viewModels()
    private var disabledResources: MutableSet<String> = mutableSetOf()


    private val serviceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(
                name: ComponentName?,
                service: IBinder?,
            ) {
                val binder = service as TunnelService.LocalBinder
                tunnelService = binder.getService()
                serviceBound = true
                tunnelService?.setServiceStateLiveData(viewModel.serviceStatusLiveData)
                tunnelService?.setResourcesLiveData(viewModel.resourcesLiveData)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                serviceBound = false
            }
        }

    private val resourcesAdapter = ResourcesAdapter(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySessionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Bind to existing TunnelService
        val intent = Intent(this, TunnelService::class.java)
        bindService(intent, serviceConnection, Context.BIND_AUTO_CREATE)

        setupViews()
        setupObservers()
    }

    override fun onDestroy() {
        super.onDestroy()
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
        }
    }

    fun onViewResourceToggled(resourceToggled: ViewResource) {
        Log.d(TAG, "Resource toggled $resourceToggled")

        if (!resourceToggled.enabled) {
            disabledResources.add(resourceToggled.id)
        } else {
            disabledResources.remove(resourceToggled.id)
        }

        tunnelService?.resourcesUpdated(disabledResources)
    }

    private fun setupViews() {
        binding.btSignOut.setOnClickListener {
            viewModel.clearToken()
            viewModel.clearActorName()
            tunnelService?.disconnect()
        }

        binding.btSettings.setOnClickListener {
            val intent = Intent(this, SettingsActivity::class.java)
            intent.putExtra("isUserSignedIn", true)
            startActivity(intent)
        }

        binding.tvActorName.text = viewModel.getActorName()

        val layoutManager = LinearLayoutManager(this@SessionActivity)
        val dividerItemDecoration =
            DividerItemDecoration(
                this@SessionActivity,
                layoutManager.orientation,
            )
        binding.rvResourcesList.addItemDecoration(dividerItemDecoration)
        binding.rvResourcesList.adapter = resourcesAdapter
        binding.rvResourcesList.layoutManager = layoutManager
    }

    private fun setupObservers() {
        // Go back to MainActivity if the service dies
        viewModel.serviceStatusLiveData.observe(this) { tunnelState ->
            if (tunnelState == TunnelService.Companion.State.DOWN) {
                finish()
            }
        }

        viewModel.resourcesLiveData.observe(this) { resources ->
            val newResources = resources.map { it.toViewResource() }
            val currentMap = resourcesAdapter.currentList.associateBy { it.id }

            for (item in newResources) {
                if (disabledResources.contains(item.id)) {
                    item.enabled = false
                }
            }


            Log.d(TAG, "Updating resource adapter with $newResources")

            resourcesAdapter.submitList(newResources)
        }
    }

    companion object {
        private const val TAG = "SessionActivity"
    }
}
