defmodule FzHttpWeb.UserLive.VPNStatusComponent do
  @moduledoc """
  Handles VPN status tag.
  """
  use FzHttpWeb, :live_component

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
    <%= cond do %>
      <% @user.disabled_at -> %>
      <span class="tag is-danger is-medium" title="This user's VPN connect is disabled by an administrator or OIDC refresh failure">DISABLED</span>
      <% @vpn_expired && @user.last_signed_in_at -> %>
      <span class="tag is-warning is-medium" title="This user's VPN connection is disabled due to authentication expiration">EXPIRED</span>
      <% @vpn_expired && !@user.last_signed_in_at -> %>
      <span class="tag is-warning is-medium" title="User must sign in to activate">EXPIRED</span>
      <% !@vpn_expired -> %>
      <span class="tag is-success is-medium" title="This user's VPN connection is enabled">ENABLED</span>
    <% end %>
    </div>
    """
  end
end
