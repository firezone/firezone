/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import android.view.View
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.DividerItemDecoration
import androidx.recyclerview.widget.LinearLayoutManager
import com.google.android.material.tabs.TabLayout
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.core.data.toggle
import dev.firezone.android.databinding.ActivitySessionBinding
import dev.firezone.android.features.settings.ui.SettingsActivity
import dev.firezone.android.tunnel.TunnelService
import androidx.lifecycle.lifecycleScope
import dev.firezone.android.tunnel.model.isInternetResource
import kotlinx.coroutines.launch

@AndroidEntryPoint
class SessionActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySessionBinding
    private var tunnelService: TunnelService? = null
    private var serviceBound = false
    private var showOnlyFavorites = false
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

    fun internetState(): ResourceState {
        return tunnelService?.internetState() ?: ResourceState.UNSET
    }

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
                    tabSelected(tab.position)

                    refreshList {
                        // TODO: we might want to remember the old position?
                        binding.rvResourcesList.scrollToPosition(0)
                    }
                }

                override fun onTabUnselected(tab: TabLayout.Tab?) {}

                override fun onTabReselected(tab: TabLayout.Tab) {}
            },
        )
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
            viewModel.repo.favorites.collect {
                refreshList()
                if (forceAllResourcesTab()) {
                    showOnlyFavorites = false
                }
            }
        }
        tabSelected(binding.tabLayout.selectedTabPosition)
    }

    fun tabSelected(position: Int) {
        showOnlyFavorites =
            when (position) {
                RESOURCES_TAB_FAVORITES -> {
                    true
                }

                RESOURCES_TAB_ALL -> {
                    false
                }

                else -> throw IllegalArgumentException("Invalid tab position: $position")
            }
    }

    private fun refreshList(afterLoad: () -> Unit = {}) {
        if (forceAllResourcesTab()) {
            binding.tabLayout.selectTab(binding.tabLayout.getTabAt(RESOURCES_TAB_ALL), true)
        }
        binding.tabLayout.visibility =
            if (viewModel.repo.favorites.value.inner.isNotEmpty()) {
                View.VISIBLE
            } else {
                View.GONE
            }

        resourcesAdapter.submitList(resourcesList(internetState())) {
            afterLoad()
        }
    }

    // The subset of Resources to actually render
    fun resourcesList(isInternetResourceEnabled: ResourceState): List<ResourceViewModel> {
        val resources =
            viewModel.resourcesLiveData.value!!.map {
                if (it.isInternetResource()) {
                    ResourceViewModel(it, isInternetResourceEnabled)
                } else {
                    ResourceViewModel(it, ResourceState.ENABLED)
                }
            }

        return if (viewModel.repo.favorites.value.inner.isEmpty()) {
            resources
        } else if (showOnlyFavorites) {
            resources.filter { viewModel.repo.favorites.value.inner.contains(it.id) }
        } else {
            resources
        }
    }

    fun forceAllResourcesTab(): Boolean {
        return viewModel.repo.favorites.value.inner.isEmpty()
    }

    companion object {
        private const val TAG = "SessionActivity"

        private const val RESOURCES_TAB_FAVORITES = 0
        private const val RESOURCES_TAB_ALL = 1
    }
}
