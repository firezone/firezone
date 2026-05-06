// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import dev.firezone.android.R
import dev.firezone.android.tunnel.model.ConnectedDevice

class ConnectedDevicesBottomSheet(
    private val devices: List<ConnectedDevice>,
) : BottomSheetDialogFragment() {
    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View? = inflater.inflate(R.layout.fragment_connected_devices, container, false)

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)

        val container: LinearLayout = view.findViewById(R.id.connectedDevicesContainer)
        val emptyText: TextView = view.findViewById(R.id.tvConnectedDevicesEmpty)

        if (devices.isEmpty()) {
            emptyText.visibility = View.VISIBLE
            container.visibility = View.GONE
            return
        }

        val inflater = LayoutInflater.from(view.context)
        devices.forEach { device ->
            val item = inflater.inflate(R.layout.list_item_connected_device, container, false)
            val idText: TextView = item.findViewById(R.id.tvDeviceId)
            val poolsLabel: TextView = item.findViewById(R.id.tvDevicePoolsLabel)
            val poolsText: TextView = item.findViewById(R.id.tvDevicePools)

            idText.text = device.id

            if (device.pools.isNotEmpty()) {
                poolsLabel.visibility = View.VISIBLE
                poolsText.visibility = View.VISIBLE
                poolsLabel.text =
                    if (device.pools.size == 1) {
                        getString(R.string.connected_devices_pool_label)
                    } else {
                        getString(R.string.connected_devices_pools_label)
                    }
                poolsText.text = device.pools.joinToString(separator = "\n")
            }

            container.addView(item)
        }
    }
}
