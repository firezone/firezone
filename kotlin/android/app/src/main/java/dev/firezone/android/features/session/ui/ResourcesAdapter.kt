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

internal class ResourcesAdapter() : ListAdapter<Resource, ResourcesAdapter.ViewHolder>(ResourceDiffCallback()) {
    private var resourcesLiveData: MutableLiveData<List<Resource>>? = null

    fun setResourcesLiveData(liveData: MutableLiveData<List<Resource>>) {
        resourcesLiveData = liveData
    }

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
        holder.bind(resource) { newResource -> onSwitchToggled(position, newResource)}
        holder.itemView.setOnClickListener {
            // Show bottom sheet
            val fragmentManager = (holder.itemView.context as AppCompatActivity).supportFragmentManager
            val bottomSheet = ResourceDetailsBottomSheet(resource)
            bottomSheet.show(fragmentManager, "ResourceDetailsBottomSheet")
        }

    }

    private fun onSwitchToggled(position: Int, resource: Resource) {
        val updatedList = currentList.toMutableList()
        updatedList[position] = resource
        resourcesLiveData?.postValue(updatedList)
    }

    class ViewHolder(private val binding: ListItemResourceBinding) : RecyclerView.ViewHolder(binding.root) {

        fun bind(resource: Resource, onSwitchToggled: (Resource) -> Unit) {
            binding.resourceNameText.text = resource.name
            binding.addressText.text = resource.address
            binding.enableSwitch.isChecked = resource.enabled

            binding.enableSwitch.setOnCheckedChangeListener {
                _, isChecked ->
                    resource.enabled = isChecked

                    onSwitchToggled(resource)
            }
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
