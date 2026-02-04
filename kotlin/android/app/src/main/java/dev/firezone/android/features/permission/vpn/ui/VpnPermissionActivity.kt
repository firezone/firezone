// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.permission.vpn.ui

import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import dev.firezone.android.databinding.ActivityVpnPermissionBinding

class VpnPermissionActivity : AppCompatActivity() {
    private lateinit var binding: ActivityVpnPermissionBinding

    private val result =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (android.net.VpnService.prepare(this) == null) {
                finish()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityVpnPermissionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.btnRequest.setOnClickListener {
            requestPermissions()
        }
    }

    private fun requestPermissions() {
        val permissionIntent = android.net.VpnService.prepare(this)
        if (permissionIntent == null) {
            // Permission already granted
            finish()
            return
        }

        result.launch(permissionIntent)
    }
}
