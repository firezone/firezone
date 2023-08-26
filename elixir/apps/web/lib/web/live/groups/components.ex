defmodule Web.Groups.Components do
  use Web, :component_library

  attr :group, :any, required: true

  def source(assigns) do
    ~H"""
    <span :if={not is_nil(@group.provider_id)}>
      Synced from <strong><%= @group.provider.name %></strong>
      <.relative_datetime datetime={@group.provider.last_synced_at} />
    </span>
    <span :if={is_nil(@group.provider_id)}>
      Created <.relative_datetime datetime={@group.inserted_at} /> by <.owner schema={@group} />
    </span>
    """
  end
end
