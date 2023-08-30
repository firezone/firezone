package dev.firezone.android.features.permission.vpn.ui

import android.app.Activity
import androidx.appcompat.app.AppCompatActivity
import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import dev.firezone.android.databinding.ActivityVpnPermissionBinding

class VpnPermissionActivity : AppCompatActivity() {

    private lateinit var binding: ActivityVpnPermissionBinding

    private val result = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        if (it.resultCode == Activity.RESULT_OK) {
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
        if (permissionIntent != null) {
            result.launch(permissionIntent)
        }
    }
}
