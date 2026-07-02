// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.content.ComponentName
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.view.View
import android.view.ViewTreeObserver
import androidx.activity.viewModels
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.google.android.material.tabs.TabLayoutMediator
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.ActivitySettingsBinding
import dev.firezone.android.tunnel.TunnelService
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySettingsBinding
    private val viewModel: SettingsViewModel by viewModels()
    private var lastFocusedView: View? = null
    private var lastSelectedPage = -1

    // Bound only while signed in, so we can live-apply the log filter to the running tunnel.
    private var tunnelService: TunnelService? = null
    private var serviceBound = false

    private val serviceConnection =
        object : ServiceConnection {
            override fun onServiceConnected(
                name: ComponentName?,
                service: IBinder?,
            ) {
                tunnelService = (service as TunnelService.LocalBinder).getService()
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                tunnelService = null
            }
        }

    private val focusTracker =
        ViewTreeObserver.OnGlobalFocusChangeListener { _, newFocus ->
            if (newFocus != null) {
                lastFocusedView = newFocus
            }
        }

    private val pageReselectionFocusRestorer =
        object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                if (position == lastSelectedPage) {
                    lastFocusedView
                        ?.takeIf { it.isAttachedToWindow && !it.hasFocus() }
                        ?.requestFocus()
                }
                lastSelectedPage = position
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivitySettingsBinding.inflate(layoutInflater)
        setContentView(binding.root)

        if (intent.getBooleanExtra("isUserSignedIn", false)) {
            // Flags = 0 so we only attach to an already-running tunnel and never start one here.
            serviceBound =
                bindService(
                    Intent(this, TunnelService::class.java),
                    serviceConnection,
                    0,
                )
        }

        setupViews()
        setupStateObservers()

        viewModel.populateFieldsFromConfig()
        viewModel.deleteLogZip(this@SettingsActivity)
    }

    private fun setupViews() {
        val adapter = SettingsPagerAdapter(this)

        with(binding) {
            viewPager.adapter = adapter

            // ViewPager2 clears focus whenever onPageSelected is dispatched, and its
            // ScrollEventAdapter re-dispatches the current page when the IME-driven
            // window resize relayouts the pager (pages > 0 produce a scroll delta on
            // relayout, which is why only the first tab was unaffected). External
            // callbacks run after the internal focus clearer, so when the current page
            // is "re-selected" we hand focus back to the view that just lost it.
            // See https://issuetracker.google.com/issues/140656866
            window.decorView.viewTreeObserver.addOnGlobalFocusChangeListener(focusTracker)
            viewPager.registerOnPageChangeCallback(pageReselectionFocusRestorer)

            TabLayoutMediator(tabLayout, viewPager) { tab, position ->
                when (position) {
                    0 -> {
                        tab.setIcon(R.drawable.rounded_discover_tune_black_24dp)
                        tab.setText("General")
                    }

                    1 -> {
                        tab.setIcon(R.drawable.rounded_settings_black_24dp)
                        tab.setText("Advanced")
                    }

                    2 -> {
                        tab.setIcon(R.drawable.rounded_description_black_24dp)
                        tab.setText("Logs")
                    }

                    else -> {
                        throw IllegalArgumentException("Invalid tab position: $position")
                    }
                }
            }.attach()

            val isUserSignedIn = intent.getBooleanExtra("isUserSignedIn", false)
            btSaveSettings.setOnClickListener {
                // The log filter is live-applied over the FFI, so only warn about a re-login when
                // a setting that actually invalidates the session changed.
                if (isUserSignedIn && viewModel.requiresReLogin()) {
                    showSaveWarningDialog()
                } else {
                    saveSettings()
                }
            }

            btCancel.setOnClickListener {
                viewModel.onCancel()
            }
        }
    }

    private fun setupStateObservers() {
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                viewModel.uiState.collect { uiState ->
                    with(binding) {
                        btSaveSettings.isEnabled = uiState.isSaveButtonEnabled
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.onViewResume(this@SettingsActivity)
    }

    private fun saveSettings() {
        // Apply the new log filter to the running tunnel so it takes effect immediately. It is
        // also persisted below and reused on the next connect.
        if (viewModel.hasLogFilterChanged()) {
            tunnelService?.setLogDirectives(viewModel.logFilter())
        }

        viewModel.onSaveSettingsCompleted()
    }

    private fun showSaveWarningDialog() {
        AlertDialog.Builder(this).apply {
            setTitle("Warning")
            setMessage("Some changed settings will not be applied until you sign out and sign back in.")
            setPositiveButton("Okay") { _, _ ->
                saveSettings()
            }
            create().show()
        }
    }

    override fun onStop() {
        super.onStop()
        if (isFinishing) {
            viewModel.deleteLogZip(this@SettingsActivity)
        }
    }

    override fun onDestroy() {
        if (serviceBound) {
            unbindService(serviceConnection)
            serviceBound = false
            tunnelService = null
        }
        window.decorView.viewTreeObserver.removeOnGlobalFocusChangeListener(focusTracker)
        binding.viewPager.unregisterOnPageChangeCallback(pageReselectionFocusRestorer)
        lastFocusedView = null
        super.onDestroy()
    }

    private inner class SettingsPagerAdapter(
        activity: FragmentActivity,
    ) : FragmentStateAdapter(activity) {
        override fun getItemCount(): Int = 3 // Three tabs

        override fun createFragment(position: Int): Fragment =
            when (position) {
                0 -> GeneralSettingsFragment()
                1 -> AdvancedSettingsFragment()
                2 -> LogSettingsFragment()
                else -> throw IllegalArgumentException("Invalid tab position: $position")
            }
    }
}
