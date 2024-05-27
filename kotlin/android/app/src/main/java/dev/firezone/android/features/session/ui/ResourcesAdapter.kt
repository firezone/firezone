/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import dev.firezone.android.databinding.ListItemResourceBinding
import dev.firezone.android.tunnel.model.Resource

internal class ResourcesAdapter(
    private var clickListener: ((Resource) -> Unit)? = null,
) : ListAdapter<Resource, ResourcesAdapter.ViewHolder>(ResourceDiffCallback()) {
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
            clickListener?.invoke(resource)
        }
    }

    class ViewHolder(private val binding: ListItemResourceBinding) : RecyclerView.ViewHolder(binding.root) {
        fun bind(resource: Resource) {
            binding.resourceNameText.text = resource.name
            binding.addressText.text = resource.address
        }
    }

    class ResourceDiffCallback : DiffUtil.ItemCallback<Resource>() {
        override fun areItemsTheSame(
            oldItem: Resource,
            newItem: Resource,
        ): Boolean {
            return oldItem.id == newItem.id
        }

        override fun areContentsTheSame(
            oldItem: Resource,
            newItem: Resource,
        ): Boolean {
            return oldItem == newItem
        }
    }
}
