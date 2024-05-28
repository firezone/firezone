/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.browser.customtabs.CustomTabsIntent
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import dev.firezone.android.R
import dev.firezone.android.tunnel.model.Resource
import dev.firezone.android.tunnel.model.StatusEnum

class ResourceDetailsBottomSheet(private val resource: Resource) : BottomSheetDialogFragment() {
    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View? {
        return inflater.inflate(R.layout.fragment_resource_details, container, false)
    }

    override fun onViewCreated(
        view: View,
        savedInstanceState: Bundle?,
    ) {
        super.onViewCreated(view, savedInstanceState)

        val resourceNameTextView: TextView = view.findViewById(R.id.tvResourceName)
        val resourceAddressTextView: TextView = view.findViewById(R.id.tvResourceAddress)
        val resourceAddressDescriptionTextView: TextView = view.findViewById(R.id.tvResourceAddressDescription)
        val siteNameTextView: TextView = view.findViewById(R.id.tvSiteName)
        val siteStatusTextView: TextView = view.findViewById(R.id.tvSiteStatus)
        val statusIndicatorDot: ImageView = view.findViewById(R.id.statusIndicatorDot)
        val labelSite: TextView = view.findViewById(R.id.labelSite)
        val siteNameLayout: LinearLayout = view.findViewById(R.id.siteNameLayout)
        val siteStatusLayout: LinearLayout = view.findViewById(R.id.siteStatusLayout)

        resourceNameTextView.text = resource.name
        val displayAddress = resource.addressDescription ?: resource.address
        resourceAddressTextView.text = displayAddress

        if (!resource.addressDescription.isNullOrEmpty()) {
            resourceAddressDescriptionTextView.text = resource.addressDescription
            resourceAddressDescriptionTextView.visibility = View.VISIBLE
        }

        val addressUri = resource.addressDescription?.let { Uri.parse(it) }
        if (addressUri != null && addressUri.scheme != null) {
            resourceAddressTextView.setTextColor(Color.BLUE)
            resourceAddressTextView.setTypeface(null, Typeface.ITALIC)
            resourceAddressTextView.setOnClickListener {
                openUrl(resource.addressDescription!!)
            }
        } else {
            resourceAddressTextView.setOnClickListener {
                copyToClipboard(displayAddress)
                Toast.makeText(requireContext(), "Address copied to clipboard", Toast.LENGTH_SHORT).show()
            }
        }

        resourceNameTextView.setOnClickListener {
            copyToClipboard(resource.name)
            Toast.makeText(requireContext(), "Name copied to clipboard", Toast.LENGTH_SHORT).show()
        }

        if (!resource.sites.isNullOrEmpty()) {
            val site = resource.sites.first()
            siteNameTextView.text = site.name
            siteNameLayout.visibility = View.VISIBLE

            // Setting site status based on resource status
            val statusText =
                when (resource.status) {
                    StatusEnum.ONLINE -> "Gateway connected"
                    StatusEnum.OFFLINE -> "All Gateways offline"
                    StatusEnum.UNKNOWN -> "No activity"
                }
            siteStatusTextView.text = statusText
            siteStatusLayout.visibility = View.VISIBLE
            labelSite.visibility = View.VISIBLE

            // Set status indicator dot color
            val dotColor =
                when (resource.status) {
                    StatusEnum.ONLINE -> Color.GREEN
                    StatusEnum.OFFLINE -> Color.RED
                    StatusEnum.UNKNOWN -> Color.GRAY
                }
            val dotDrawable = GradientDrawable()
            dotDrawable.shape = GradientDrawable.OVAL
            dotDrawable.setColor(dotColor)
            statusIndicatorDot.setImageDrawable(dotDrawable)
            statusIndicatorDot.visibility = View.VISIBLE

            siteNameTextView.setOnClickListener {
                copyToClipboard(site.name)
                Toast.makeText(requireContext(), "Site name copied to clipboard", Toast.LENGTH_SHORT).show()
            }
        }
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
