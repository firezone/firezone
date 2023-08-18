defmodule Web.Actors.Components do
  use Web, :component_library

  def account_type_to_string(type) do
    case type do
      :account_admin_user -> "Admin"
      :account_user -> "User"
      :service_account -> "Service Account"
    end
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true
  attr :class, :string, default: ""

  def actor_name_and_role(assigns) do
    ~H"""
    <.link
      navigate={~p"/#{@account}/actors/#{@actor.id}"}
      class={["font-medium text-blue-600 dark:text-blue-500 hover:underline", @class]}
    >
      <%= @actor.name %>
    </.link>
    <span :if={@actor.type == :account_admin_user} class={["text-xs", @class]}>
      (admin)
    </span>
    <span :if={@actor.type == :service_account} class={["text-xs", @class]}>
      (service account)
    </span>
    """
  end
end
