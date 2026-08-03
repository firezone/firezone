defmodule PortalWeb.AuthorizationComponents do
  @moduledoc "Shared UI for policy authorization views."

  use Phoenix.Component
  use PortalWeb, :verified_routes

  attr :account, :any, required: true

  def authorization_flow_logs_notice(assigns) do
    ~H"""
    <div
      data-authorization-flow-logs-notice
      class="shrink-0 border-b border-border bg-raised/40 px-4 py-2 text-xs text-subtle"
    >
      See
      <.link navigate={~p"/#{@account}/logs/flow_logs"} class="text-brand">
        <span class="hover:underline">flow logs</span>
      </.link>
      for detailed access logs.
    </div>
    """
  end
end
