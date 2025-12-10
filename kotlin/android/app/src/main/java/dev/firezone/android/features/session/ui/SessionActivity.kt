// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
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
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import com.google.android.material.tabs.TabLayout
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.toggle
import dev.firezone.android.databinding.ActivitySessionBinding
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.launch

@AndroidEntryPoint
class SessionActivity : AppCompatActivity() {
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
                val binder = service as TunnelService.LocalBinder
                tunnelService = binder.getService()

                tunnelService?.let {
                    serviceBound = true
                    it.setServiceStateLiveData(viewModel.serviceStatusLiveData)
                    it.setResourcesLiveData(viewModel.resourcesLiveData)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                serviceBound = false
            }
        }

    private val resourcesAdapter = ResourcesAdapter { this.onInternetResourceToggled() }

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
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
            tunnelService = null
        }

        super.onDestroy()
    }

    fun internetState(): ResourceState = tunnelService?.internetState() ?: ResourceState.UNSET

    private fun onInternetResourceToggled(): ResourceState {
        tunnelService?.let {
            it.internetResourceToggled(internetState().toggle())
            refreshList()
            Log.d(TAG, "Internet resource toggled ${internetState()}")
        }

        return internetState()
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

        binding.tabLayout.addOnTabSelectedListener(
            object : TabLayout.OnTabSelectedListener {
                override fun onTabSelected(tab: TabLayout.Tab) {
                    viewModel.tabSelected(tab.position)

                    refreshList {
                        // TODO: we might want to remember the old position?
                        binding.rvResourcesList.scrollToPosition(0)
                    }
                }

                override fun onTabUnselected(tab: TabLayout.Tab?) {}

                override fun onTabReselected(tab: TabLayout.Tab) {}
            },
        )
        viewModel.tabSelected(binding.tabLayout.selectedTabPosition)
    }

    private fun setupObservers() {
        // Go back to MainActivity if the service dies
        viewModel.serviceStatusLiveData.observe(this) { tunnelState ->
            if (tunnelState == TunnelService.Companion.State.DOWN) {
                finish()
            }
        }

        viewModel.resourcesLiveData.observe(this) {
            refreshList()
        }

        // This coroutine could still resume while the Activity is not shown, but this is probably
        // fine since the Flow will only emit if the user interacts with the UI anyway.
        lifecycleScope.launch {
            viewModel.favorites.collect {
                refreshList()
            }
        }
        viewModel.tabSelected(binding.tabLayout.selectedTabPosition)
    }

    private fun refreshList(afterLoad: () -> Unit = {}) {
        viewModel.forceTab()?.let { tab -> binding.tabLayout.selectTab(binding.tabLayout.getTabAt(tab), true) }

        binding.tabLayout.visibility = viewModel.tabLayoutVisibility()
        resourcesAdapter.submitList(viewModel.resourcesList(internetState())) {
            afterLoad()
        }
    }

    companion object {
        private const val TAG = "SessionActivity"
    }
}
