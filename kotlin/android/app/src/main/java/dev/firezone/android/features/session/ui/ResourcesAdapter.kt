package dev.firezone.android.features.session.ui

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import dev.firezone.android.databinding.ListItemResourceBinding
import dev.firezone.android.tunnel.model.Resource
import javax.annotation.Nullable

internal class ResourcesAdapter: RecyclerView.Adapter<ResourcesAdapter.ViewHolder>() {

    private val resources: MutableList<Resource> = mutableListOf()

    fun updateResources(updatedResources: List<Resource>) {
        val diffCallback = ResourcesCallback(resources, updatedResources)
        val diffCourses = DiffUtil.calculateDiff(diffCallback)
        resources.clear()
        resources.addAll(updatedResources)
        diffCourses.dispatchUpdatesTo(this)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        return ViewHolder(
            ListItemResourceBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        )
    }

    override fun getItemCount(): Int = resources.size

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        holder.bind(resources[position])
    }

    class ViewHolder(private val binding: ListItemResourceBinding) : RecyclerView.ViewHolder(binding.root) {
        fun bind(resource: Resource) {
            binding.resourceNameText.text = resource.name
            binding.typeChip.text = resource.type
            binding.addressText.text = resource.address
        }
    }
}

class ResourcesCallback(private val oldList: List<Resource>, private val newList: List<Resource>) : DiffUtil.Callback() {
    override fun getOldListSize(): Int = oldList.size

    override fun getNewListSize(): Int = newList.size

    override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
        return oldList[oldItemPosition] === newList[newItemPosition]
    }

    override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int): Boolean {
        val (type1, id1, address1, name1) = oldList[oldItemPosition]
        val (type2, id2, address2, name2) = newList[newItemPosition]
        return type1 == type2 && id1 == id2 && address1 == address2 && name1 == name2
    }
}
