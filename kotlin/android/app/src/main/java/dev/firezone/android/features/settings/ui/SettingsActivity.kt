// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.settings.ui

import android.os.Bundle
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
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.R
import dev.firezone.android.databinding.ActivitySettingsBinding
import kotlinx.coroutines.launch

/** The navigation item and the page it shows, in order. */
internal val settingsPages: List<Pair<Int, () -> Fragment>> =
    listOf(
        R.id.settingsGeneral to { GeneralSettingsFragment() },
        R.id.settingsAdvanced to { AdvancedSettingsFragment() },
        R.id.settingsX509 to { X509SettingsFragment() },
        R.id.settingsLogs to { LogSettingsFragment() },
    )

@AndroidEntryPoint
internal class SettingsActivity : AppCompatActivity() {
    private lateinit var binding: ActivitySettingsBinding
    private val viewModel: SettingsViewModel by viewModels()
    private var lastFocusedView: View? = null
    private var lastSelectedPage = -1

    private val navigationSelectionSync =
        object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                // By id rather than by menu position, which would assume the menu is ordered like
                // the pager. Checking the item rather than assigning `selectedItemId`, which would
                // call back into the item listener and drive the pager again.
                binding.bottomNavigation.menu
                    .findItem(settingsPages[position].first)
                    .isChecked = true
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
            viewPager.registerOnPageChangeCallback(navigationSelectionSync)

            bottomNavigation.setOnItemSelectedListener { item ->
                val position = settingsPages.indexOfFirst { it.first == item.itemId }

                if (position < 0) {
                    return@setOnItemSelectedListener false
                }

                // Without smooth scrolling, so that jumping across the bar does not create and
                // then discard every fragment in between.
                viewPager.setCurrentItem(position, false)

                true
            }

            val isUserSignedIn = intent.getBooleanExtra("isUserSignedIn", false)
            if (isUserSignedIn) {
                btSaveSettings.setOnClickListener {
                    showSaveWarningDialog()
                }
            } else {
                btSaveSettings.setOnClickListener {
                    viewModel.onSaveSettingsCompleted()
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

    private fun showSaveWarningDialog() {
        AlertDialog.Builder(this).apply {
            setTitle("Warning")
            setMessage("Some changed settings will not be applied until you sign out and sign back in.")
            setPositiveButton("Okay") { _, _ ->
                viewModel.onSaveSettingsCompleted()
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
        window.decorView.viewTreeObserver.removeOnGlobalFocusChangeListener(focusTracker)
        binding.viewPager.unregisterOnPageChangeCallback(pageReselectionFocusRestorer)
        binding.viewPager.unregisterOnPageChangeCallback(navigationSelectionSync)
        lastFocusedView = null
        super.onDestroy()
    }

    private inner class SettingsPagerAdapter(
        activity: FragmentActivity,
    ) : FragmentStateAdapter(activity) {
        override fun getItemCount(): Int = settingsPages.size

        override fun createFragment(position: Int): Fragment = settingsPages[position].second()
    }
}
