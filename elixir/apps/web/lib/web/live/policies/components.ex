defmodule Web.Policies.Components do
  use Web, :component_library

  attr :policy, :map, required: true

  def policy_name(assigns) do
    ~H"<%= @policy.actor_group.name %> → <%= @policy.resource.name %>"
  end
end
