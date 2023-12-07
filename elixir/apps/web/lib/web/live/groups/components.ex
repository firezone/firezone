defmodule Web.Groups.Components do
  use Web, :component_library

  attr :account, :any, required: true
  attr :group, :any, required: true

  def source(assigns) do
    ~H"""
    <span :if={not is_nil(@group.provider_id)}>
      Synced from
      <.link
        class="font-medium text-accent-600 hover:underline"
        navigate={Web.Settings.IdentityProviders.Components.view_provider(@account, @group.provider)}
      >
        <%= @group.provider.name %>
      </.link>
      <.relative_datetime datetime={@group.provider.last_synced_at} />
    </span>
    <span :if={is_nil(@group.provider_id)}>
      <.created_by account={@account} schema={@group} />
    </span>
    """
  end
end
