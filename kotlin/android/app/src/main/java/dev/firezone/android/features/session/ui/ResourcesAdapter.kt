// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.features.session.ui

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import dev.firezone.android.core.data.ResourceState
import dev.firezone.android.databinding.ListItemResourceBinding

internal class ResourcesAdapter(
    private val internetResourceToggle: () -> ResourceState,
) : ListAdapter<ResourceViewModel, ResourcesAdapter.ViewHolder>(
        ResourceDiffCallback(),
    ) {
    override fun onCreateViewHolder(
        parent: ViewGroup,
        viewType: Int,
    ): ViewHolder {
        val binding = ListItemResourceBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return ViewHolder(binding)
    }

    override fun onBindViewHolder(
        holder: ViewHolder,
        position: Int,
    ) {
        val resource = getItem(position)
        holder.bind(resource)
        holder.itemView.setOnClickListener {
            // Show bottom sheet
            val fragmentManager =
                (holder.itemView.context as AppCompatActivity).supportFragmentManager
            val bottomSheet = ResourceDetailsBottomSheet(resource, internetResourceToggle)
            bottomSheet.show(fragmentManager, "ResourceDetailsBottomSheet")
        }
    }

    class ViewHolder(
        private val binding: ListItemResourceBinding,
    ) : RecyclerView.ViewHolder(binding.root) {
        fun bind(resource: ResourceViewModel) {
            binding.resourceNameText.text = resource.displayName
            if (resource.isInternetResource()) {
                binding.addressText.visibility = View.GONE
            } else {
                binding.addressText.text = resource.address
            }
        }
    }

    class ResourceDiffCallback : DiffUtil.ItemCallback<ResourceViewModel>() {
        override fun areItemsTheSame(
            oldItem: ResourceViewModel,
            newItem: ResourceViewModel,
        ): Boolean = oldItem.id == newItem.id

        override fun areContentsTheSame(
            oldItem: ResourceViewModel,
            newItem: ResourceViewModel,
        ): Boolean = oldItem == newItem
    }
}
