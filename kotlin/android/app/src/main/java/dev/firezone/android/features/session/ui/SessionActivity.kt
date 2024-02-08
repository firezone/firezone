/* Licensed under Apache 2.0 (C) 2023 Firezone, Inc. */
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
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.core.utils.ClipboardUtils
import dev.firezone.android.databinding.ActivitySessionBinding
import dev.firezone.android.tunnel.TunnelService
import dev.firezone.android.tunnel.model.Resource

@AndroidEntryPoint
internal class SessionActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySessionBinding
    private var tunnelService: TunnelService? = null
    private var serviceBound = false
    private val viewModel: SessionViewModel by viewModels()

    private val serviceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(
                name: ComponentName?,
                service: IBinder?,
            ) {
                Log.d(TAG, "onServiceConnected")
                val binder = service as TunnelService.LocalBinder
                tunnelService = binder.getService()
                serviceBound = true
                tunnelService?.setServiceStateLiveData(viewModel.serviceStatusLiveData)
                tunnelService?.setResourcesLiveData(viewModel.resourcesLiveData)
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                Log.d(TAG, "onServiceDisconnected")
                serviceBound = false
            }
        }
    private val resourcesAdapter: ResourcesAdapter =
        ResourcesAdapter { resource ->
            ClipboardUtils.copyToClipboard(this@SessionActivity, resource.name, resource.address)
        }

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

    private fun setupViews() {
        binding.btSignOut.setOnClickListener {
            Log.d(TAG, "Sign out button clicked")
            viewModel.clearToken()

            tunnelService?.disconnect()

            finish()
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

        // Hack to show a connecting message until the service is bound
        resourcesAdapter.updateResources(listOf(Resource("", "", "", "Connecting...")))
    }

    private fun setupObservers() {
        // Go back to MainActivity if the service dies
        viewModel.serviceStatusLiveData.observe(this) { tunnelState ->
            if (tunnelState == TunnelService.Companion.State.DOWN) {
                // Start MainActivity which will show the Sign in fragment
                startActivity(Intent(this, MainActivity::class.java))
            }
        }

        viewModel.resourcesLiveData.observe(this) { resources ->
            resourcesAdapter.updateResources(resources)
        }
    }

    companion object {
        private const val TAG = "SessionActivity"
    }
}
