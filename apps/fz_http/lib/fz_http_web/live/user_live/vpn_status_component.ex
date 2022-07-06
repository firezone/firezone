defmodule FzHttpWeb.UserLive.VPNStatusComponent do
  @moduledoc """
  Handles VPN status tag.
  """
  use FzHttpWeb, :live_component

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <label>
    <%= cond do %>
      <% @user.disabled_at -> %>
      <span class="tag is-danger is-medium" title="This user's VPN connect is disabled by an administrator or OIDC refresh error">DISABLED</span>
      <% @vpn_expired && @user.last_signed_in_at -> %>
      <span class="tag is-warning is-medium" title="This user's VPN connection is disabled due to authentication expiration">EXPIRED</span>
      <% @vpn_expired && !@user.last_signed_in_at -> %>
      <span class="tag is-warning is-medium" title="User must sign in to activate">EXPIRED</span>
      <% !@vpn_expired -> %>
      <span class="tag is-success is-medium" title="This user's VPN connection is enabled">ENABLED</span>
    <% end %>
    </label>
    """
  end
end
