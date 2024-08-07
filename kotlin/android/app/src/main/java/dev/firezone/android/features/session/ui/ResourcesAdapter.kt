/* Licensed under Apache 2.0 (C) 2024 Firezone, Inc. */
package dev.firezone.android.features.session.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.ListAdapter
import androidx.recyclerview.widget.RecyclerView
import dev.firezone.android.databinding.ListItemResourceBinding

internal class ResourcesAdapter(private val activity: SessionActivity) : ListAdapter<ViewResource, ResourcesAdapter.ViewHolder>(
    ResourceDiffCallback(),
) {
    private var favoriteResources: HashSet<String> = HashSet()

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
        holder.bind(resource) { newResource -> onSwitchToggled(newResource) }
        holder.itemView.setOnClickListener {
            // Show bottom sheet
            val isFavorite = favoriteResources.contains(resource.id)
            val fragmentManager = (holder.itemView.context as AppCompatActivity).supportFragmentManager
            val bottomSheet = ResourceDetailsBottomSheet(resource)
            bottomSheet.show(fragmentManager, "ResourceDetailsBottomSheet")
        }
    }

    private fun onSwitchToggled(resource: ViewResource) {
        activity.onViewResourceToggled(resource)
    }

    class ViewHolder(private val binding: ListItemResourceBinding) : RecyclerView.ViewHolder(binding.root) {
        fun bind(
            resource: ViewResource,
            onSwitchToggled: (ViewResource) -> Unit,
        ) {
            binding.resourceNameText.text = resource.name
            binding.addressText.text = resource.address
            // Without this the item gets reset when out of view, isn't android wonderful?
            binding.enableSwitch.setOnCheckedChangeListener(null)
            binding.enableSwitch.isChecked = resource.enabled
            binding.enableSwitch.isVisible = resource.canToggle

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
