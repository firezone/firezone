package dev.firezone.android.features.session.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import dev.firezone.android.R
import dev.firezone.android.tunnel.model.Resource

class ResourceDetailsBottomSheet(private val resource: Resource) : BottomSheetDialogFragment() {

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        return inflater.inflate(R.layout.fragment_resource_details, container, false)
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        val resourceNameTextView: TextView = view.findViewById(R.id.tvResourceName)
        val resourceAddressTextView: TextView = view.findViewById(R.id.tvResourceAddress)

        resourceNameTextView.text = resource.name
        resourceAddressTextView.text = resource.address

        resourceNameTextView.setOnClickListener {
            copyToClipboard(resource.name)
            Toast.makeText(requireContext(), "Name copied to clipboard", Toast.LENGTH_SHORT).show()
        }

        resourceAddressTextView.setOnClickListener {
            val url = Uri.parse(resource.address)
            if (url.scheme != null) {
                openUrl(resource.address)
            } else {
                copyToClipboard(resource.address)
                Toast.makeText(requireContext(), "Address copied to clipboard", Toast.LENGTH_SHORT).show()
            }
        }

        // Handle additional fields like site name, status, etc.
    }

    private fun copyToClipboard(text: String) {
        val clipboard = requireContext().getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("Copied Text", text)
        clipboard.setPrimaryClip(clip)
    }

    private fun openUrl(url: String) {
        val builder = CustomTabsIntent.Builder()
        val customTabsIntent = builder.build()
        customTabsIntent.launchUrl(requireContext(), Uri.parse(url))
    }
}
