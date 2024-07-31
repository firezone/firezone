/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.util.Log
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.MutableLiveData
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.ListUpdateCallback
import androidx.recyclerview.widget.RecyclerView
import dev.firezone.android.databinding.ListItemResourceBinding
import dev.firezone.android.tunnel.model.Resource

internal class ResourcesAdapter(private val activity: SessionActivity) : ListAdapter<ViewResource, ResourcesAdapter.ViewHolder>(ResourceDiffCallback()) {
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
        holder.bind(resource) { newResource -> onSwitchToggled(newResource)}
        holder.itemView.setOnClickListener {
            // Show bottom sheet
            val fragmentManager = (holder.itemView.context as AppCompatActivity).supportFragmentManager
            val bottomSheet = ResourceDetailsBottomSheet(resource)
            bottomSheet.show(fragmentManager, "ResourceDetailsBottomSheet")
        }

    }

    private fun onSwitchToggled(resource: ViewResource) {
        val updatedList = currentList.toMutableList().associateBy{ it.id }.toMutableMap()
        updatedList[resource.id]?.let {
            updatedList[resource.id] = resource
        }

        val newList = updatedList.values.toList()
        // Man... this is a round about way to update the list
        submitList(newList)

        activity.viewResourceUpdate(newList)
    }

    class ViewHolder(private val binding: ListItemResourceBinding) : RecyclerView.ViewHolder(binding.root) {

        fun bind(resource: ViewResource, onSwitchToggled: (ViewResource) -> Unit) {
            binding.resourceNameText.text = resource.name
            binding.addressText.text = resource.address
            // Without this the item gets reset when out of view, isn't android wonderful?
            binding.enableSwitch.setOnCheckedChangeListener(null)
            binding.enableSwitch.isChecked = resource.enabled

            binding.enableSwitch.setOnCheckedChangeListener {
                _, isChecked ->
                    resource.enabled = isChecked

                    onSwitchToggled(resource)
            }
        }

    }

    class ResourceDiffCallback : DiffUtil.ItemCallback<ViewResource>() {
        override fun areItemsTheSame(
            oldItem: ViewResource,
            newItem: ViewResource,
        ): Boolean {
            return oldItem.id == newItem.id
        }

        override fun areContentsTheSame(
            oldItem: ViewResource,
            newItem: ViewResource,
        ): Boolean {
            return oldItem == newItem
        }
    }
}
