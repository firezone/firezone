package dev.firezone.android.features.permission.vpn.ui

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.view.View
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.navigation.fragment.findNavController
import dev.firezone.android.R
import dagger.hilt.android.AndroidEntryPoint
import dev.firezone.android.databinding.FragmentVpnPermissionBinding
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@AndroidEntryPoint
internal class VpnPermissionFragment : Fragment(R.layout.fragment_vpn_permission) {

    private val result = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        Log.d("PermissionFragment", "requestPermissions: $it")
        if (it.resultCode == Activity.RESULT_OK) {
            lifecycleScope.launch {
                delay(3000L)
                findNavController().navigateUp()
            }
        }
    }

    private lateinit var binding: FragmentVpnPermissionBinding
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        binding = FragmentVpnPermissionBinding.bind(view)

        binding.btnRequest.setOnClickListener {
            requestPermissions()
        }
    }

    private fun requestPermissions() {
        val permissionIntent = android.net.VpnService.prepare(requireActivity())
        if (permissionIntent != null) {
            result.launch(permissionIntent)
        }
    }
}
