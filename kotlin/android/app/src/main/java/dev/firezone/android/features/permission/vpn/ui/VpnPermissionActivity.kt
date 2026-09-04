// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.permission.vpn.ui

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import dev.firezone.android.R
import dev.firezone.android.features.permission.ui.compose.PermissionScreen
import dev.firezone.android.features.session.ui.compose.FirezoneTheme

class VpnPermissionActivity : AppCompatActivity() {
    private val result =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (android.net.VpnService.prepare(this) == null) {
                finish()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        setContent {
            FirezoneTheme {
                PermissionScreen(
                    title = R.string.enable_vpn_permission,
                    description = R.string.vpn_permission_description,
                    actionLabel = R.string.request_permission,
                    onAction = ::requestPermissions,
                )
            }
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
