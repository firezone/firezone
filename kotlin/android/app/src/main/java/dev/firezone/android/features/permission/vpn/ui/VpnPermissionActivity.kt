/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.permission.vpn.ui

import android.app.Activity
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import dev.firezone.android.databinding.ActivityVpnPermissionBinding

class VpnPermissionActivity : AppCompatActivity() {
    private lateinit var binding: ActivityVpnPermissionBinding

    private val result =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (it.resultCode == Activity.RESULT_OK) {
                finish()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityVpnPermissionBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Check if permission is already granted and finish immediately if so
        if (vpnPermissionIntent() == null) {
            finish()
        }

        binding.btnRequest.setOnClickListener {
            requestPermissions()
        }
    }

    private fun requestPermissions() {
        val permissionIntent = vpnPermissionIntent()

        if (permissionIntent == null) {
            finish()
            return;
        }

        result.launch(permissionIntent)
    }

    private fun vpnPermissionIntent() {
        return android.net.VpnService.prepare(this)
    }
}
