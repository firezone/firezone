// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.permission.notification.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.core.data.Repository
import dev.firezone.android.databinding.ActivityNotificationPermissionBinding
import javax.inject.Inject

@AndroidEntryPoint
class NotificationPermissionActivity : AppCompatActivity() {
    private lateinit var binding: ActivityNotificationPermissionBinding

    @Inject
    lateinit var repository: Repository

    private val requestPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted ->
            // Mark that we've requested permission regardless of the result
            repository.setNotificationPermissionRequested()
            // Always finish - we don't fail if user denies
            finish()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityNotificationPermissionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnRequest.setOnClickListener {
            requestNotificationPermission()
        }

        binding.btnSkip.setOnClickListener {
            // Mark as requested even if user skips
            repository.setNotificationPermissionRequested()
            finish()
        }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            when {
                ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED -> {
                    // Permission already granted
                    repository.setNotificationPermissionRequested()
                    finish()
                }

                else -> {
                    // Request permission
                    requestPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            }
        } else {
            // Notification permission not needed for Android < 13
            repository.setNotificationPermissionRequested()
            finish()
        }
    }
}
