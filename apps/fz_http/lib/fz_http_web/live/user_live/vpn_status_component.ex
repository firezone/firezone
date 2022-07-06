defmodule FzHttpWeb.UserLive.VPNStatusComponent do
  @moduledoc """
  Handles VPN status tag.
  """
  use FzHttpWeb, :live_component

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <%= tag_for_vpn_status(@user, @vpn_expired, assigns) %>
    </div>
    """
  end

  defp tag_for_vpn_status(user, expired, assigns) do
    cond do
      user.disabled_at -> disabled_tag(assigns)
      expired && user.last_signed_in_at -> expired_tag_sign_in(assigns)
      expired && is_nil(user.last_signed_in_at) -> expired_tag_auth(assigns)
      !expired -> enabled_tag(assigns)
    end
  end

  defp disabled_tag(assigns) do
    ~H"""
    <span class="tag is-danger is-medium" title="This user's VPN connect is disabled by an administrator or OIDC refresh failure">DISABLED</span>
    """
  end

  defp enabled_tag(assigns) do
    ~H"""
    <span class="tag is-success is-medium" title="This user's VPN connection is enabled">ENABLED</span>
    """
  end

  defp expired_tag_sign_in(assigns) do
    ~H"""
    <span class="tag is-warning is-medium" title="This user's VPN connection is disabled due to authentication expiration">EXPIRED</span>
    """
  end

  defp expired_tag_auth(assigns) do
    ~H"""
    <span class="tag is-warning is-medium" title="User must sign in to activate">EXPIRED</span>
    """
  end
end
