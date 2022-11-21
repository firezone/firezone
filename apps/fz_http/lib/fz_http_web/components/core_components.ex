defmodule FzHttpWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.
  """
  use Phoenix.Component
  use FzHttpWeb, :helper
  use Phoenix.HTML
  import FzHttpWeb.AuthorizationHelpers
  import FzHttpWeb.ErrorHelpers

  def device_details(assigns) do
    ~H"""
    <table class="table is-bordered is-hoverable is-striped is-fullwidth">
      <tbody>
        <%= if has_role?(@current_user, :admin) do %>
          <tr>
            <td><strong>User</strong></td>
            <td>
              <%= live_redirect(@user.email, to: ~p"/users/#{@user}") %>
            </td>
          </tr>
        <% end %>

        <tr>
          <td><strong>Name</strong></td>
          <td><%= @device.name %></td>
        </tr>

        <tr>
          <td><strong>Description</strong></td>
          <td><%= @device.description %></td>
        </tr>

        <%= if Application.fetch_env!(:fz_http, :wireguard_ipv4_enabled) do %>
          <tr>
            <td><strong>Interface IPv4</strong></td>
            <td><%= @device.ipv4 %></td>
          </tr>
        <% end %>

        <%= if Application.fetch_env!(:fz_http, :wireguard_ipv6_enabled) do %>
          <tr>
            <td><strong>Interface IPv6</strong></td>
            <td><%= @device.ipv6 %></td>
          </tr>
        <% end %>

        <tr>
          <td><strong>Remote IP</strong></td>
          <td><%= @device.remote_ip %></td>
        </tr>

        <tr>
          <td><strong>Latest Handshake</strong></td>
          <td
            id={"device-#{@device.id}-latest-handshake"}
            data-timestamp={@device.latest_handshake}
            phx-hook="FormatTimestamp"
          >
            …
          </td>
        </tr>

        <tr>
          <td><strong>Received</strong></td>
          <td><%= FzCommon.FzInteger.to_human_bytes(@device.rx_bytes) %></td>
        </tr>

        <tr>
          <td><strong>Sent</strong></td>
          <td><%= FzCommon.FzInteger.to_human_bytes(@device.tx_bytes) %></td>
        </tr>

        <tr>
          <td><strong>Allowed IPs</strong></td>
          <td><%= @allowed_ips || "None" %></td>
        </tr>

        <tr>
          <td><strong>DNS Servers</strong></td>
          <td><%= @dns || "None" %></td>
        </tr>

        <tr>
          <td><strong>Endpoint</strong></td>
          <td><%= @endpoint %>:<%= @port %></td>
        </tr>

        <tr>
          <td><strong>Persistent Keepalive</strong></td>
          <td>
            <%= if @persistent_keepalive == 0 do %>
              Disabled
            <% else %>
              Every <%= @persistent_keepalive %> seconds
            <% end %>
          </td>
        </tr>

        <tr>
          <td><strong>MTU</strong></td>
          <td><%= @mtu %></td>
        </tr>

        <tr>
          <td><strong>Public key</strong></td>
          <td class="code"><%= @device.public_key %></td>
        </tr>

        <tr>
          <td><strong>Preshared Key</strong></td>
          <td class="code"><%= @device.preshared_key %></td>
        </tr>
      </tbody>
    </table>
    """
  end

  def devices_table(assigns) do
    ~H"""
    <table class="table is-bordered is-hoverable is-striped is-fullwidth">
      <thead>
        <tr>
          <th>Name</th>
          <%= if @show_user do %>
            <th>User</th>
          <% end %>
          <th>WireGuard IP</th>
          <th>Remote IP</th>
          <th>Latest Handshake</th>
          <th>Transfer</th>
          <th>Public key</th>
          <th>Created</th>
          <th>Updated</th>
        </tr>
      </thead>
      <tbody>
        <%= for device <- @devices do %>
          <tr>
            <td>
              <.link navigate={~p"/devices/#{device}"}>
                <%= device.name %>
              </.link>
            </td>
            <%= if @show_user do %>
              <td>
                <%= live_redirect(device.user.email,
                  to: ~p"/users/#{device.user}"
                ) %>
              </td>
            <% end %>
            <td class="code">
              <%= device.ipv4 %>
              <br />
              <%= device.ipv6 %>
            </td>
            <td class="code">
              <%= device.remote_ip %>
            </td>
            <td
              id={"device-#{device.id}-latest-handshake"}
              data-timestamp={device.latest_handshake}
              phx-hook="FormatTimestamp"
            >
              …
            </td>
            <td class="code">
              <%= FzCommon.FzInteger.to_human_bytes(device.rx_bytes) %> received <br />
              <%= FzCommon.FzInteger.to_human_bytes(device.tx_bytes) %> sent
            </td>
            <td class="code"><%= device.public_key %></td>
            <td
              id={"device-#{device.id}-inserted-at"}
              data-timestamp={device.inserted_at}
              phx-hook="FormatTimestamp"
            >
              …
            </td>
            <td
              id={"device-#{device.id}-updated-at"}
              data-timestamp={device.updated_at}
              phx-hook="FormatTimestamp"
            >
              …
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  def flash(assigns) do
    ~H"""
    <%= if !is_nil(live_flash(@flash, :info)) or !is_nil(live_flash(@flash, :error)) do %>
      <div class="content flash-squeeze">
        <%= if live_flash(@flash, :info) do %>
          <div class="notification is-info">
            <button
              title="Dismiss notification"
              class="delete"
              phx-click="lv:clear-flash"
              phx-value-key="info"
            >
            </button>
            <div class="flash-info"><%= live_flash(@flash, :info) %></div>
          </div>
        <% end %>
        <%= if live_flash(@flash, :error) do %>
          <div class="notification is-danger">
            <button
              title="Dismiss notification"
              class="delete"
              phx-click="lv:clear-flash"
              phx-value-key="error"
            >
            </button>
            <div class="flash-error"><%= live_flash(@flash, :error) %></div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  def heading(assigns) do
    ~H"""
    <section class="hero is-hero-bar">
      <div class="hero-body">
        <div class="block">
          <h1 class="title">
            <%= @page_title %>
          </h1>
        </div>
        <%= if assigns[:page_subtitle] do %>
          <div class="block">
            <p><%= @page_subtitle %></p>
          </div>
        <% end %>
      </div>
    </section>
    """
  end

  def mfa_methods_table(assigns) do
    ~H"""
    <table class="table is-bordered is-hoverable is-striped is-fullwidth">
      <thead>
        <tr>
          <th>Name</th>
          <th>Type</th>
          <th>Last Used At</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        <%= for method <- @methods do %>
          <tr>
            <td>
              <%= method.name %>
            </td>
            <td>
              <%= method.type %>
            </td>
            <td
              id={"method-#{method.id}-last-used-at"}
              data-timestamp={method.last_used_at}
              phx-hook="FormatTimestamp"
            >
              …
            </td>
            <td>
              <button
                class="button is-warning"
                data-confirm={"Are you sure about deleting this authenticator <#{method.name}>?"}
                phx-click="delete_authenticator"
                phx-value-id={method.id}
              >
                <span class="icon is-small">
                  <i class="fas fa-trash"></i>
                </span>
                <span>Delete</span>
              </button>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  def password_field(assigns) do
    ~H"""
    <div class="field">
      <%= label(@context, @field, @label, class: "label") %>

      <div class="control">
        <%= password_input(
          @context,
          @field,
          class: "input password",
          id: "#{@field}-field",
          autocomplete: "new-password",
          data_target: "#{@field}-progress",
          phx_hook: "PasswordStrength"
        ) %>
      </div>
      <p class="help is-danger">
        <%= error_tag(@context, @field) %>
      </p>

      <progress id={"#{@field}-progress"} class="is-hidden" value="0" max="100">0%</progress>
    </div>
    """
  end

  def show_device(assigns) do
    ~H"""
    <section class="section is-main-section">
      <.flash {assigns} />

      <h4 class="title is-4">Details</h4>

      <.device_details {assigns} />
    </section>

    <%= if FzHttpWeb.Layouts.can_manage_devices?(@current_user) do %>
      <section class="section is-main-section">
        <h4 class="title is-4">
          Danger Zone
        </h4>

        <button
          class="button is-danger"
          id="delete-device-button"
          phx-click="delete_device"
          phx-value-device_id={@device.id}
          data-confirm="Are you sure? This will immediately disconnect this device and remove all associated data."
        >
          <span class="icon is-small">
            <i class="fas fa-trash"></i>
          </span>
          <span>Delete Device <%= @device.name %></span>
        </button>
      </section>
    <% end %>
    """
  end

  def socket_token_headers(assigns) do
    ~H"""
    <!-- User Socket -->
    <%= content_tag(:meta,
      name: "user-token",
      content: Phoenix.Token.sign(@conn, "user auth", @current_user.id)
    ) %>
    <!-- Notification Channel -->
    <%= content_tag(:meta,
      name: "channel-token",
      content: Phoenix.Token.sign(@conn, "channel auth", @current_user.id)
    ) %>
    <!-- CSRF -->
    <%= csrf_meta_tag() %>
    """
  end

  def submit_button(assigns) do
    ~H"""
    <div class="field">
      <div class="control">
        <div class="level">
          <div class="level-left"></div>
          <div class="level-right">
            <%= submit(assigns[:button_text] || "Save",
              phx_disable_with: "Saving...",
              form: assigns[:form],
              class: "button is-primary"
            ) %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def user_details(assigns) do
    ~H"""
    <table class="table is-bordered is-hoverable is-striped is-fullwidth">
      <tbody>
        <tr>
          <td><strong>Email</strong></td>
          <td><%= @user.email %></td>
        </tr>

        <tr>
          <td><strong>Role</strong></td>
          <td><%= @user.role %></td>
        </tr>

        <tr>
          <td><strong>Last Signed In</strong></td>
          <td
            id="last-signed-in-at"
            data-timestamp={@user.last_signed_in_at}
            phx-hook="FormatTimestamp"
          >
            …
          </td>
        </tr>

        <tr>
          <td><strong>Created</strong></td>
          <td
            id={"user-#{@user.id}-created-at"}
            data-timestamp={@user.inserted_at}
            phx-hook="FormatTimestamp"
          >
            …
          </td>
        </tr>

        <tr>
          <td><strong>Updated</strong></td>
          <td
            id={"user-#{@user.id}-updated-at"}
            data-timestamp={@user.updated_at}
            phx-hook="FormatTimestamp"
          >
            …
          </td>
        </tr>

        <tr>
          <td><strong>Number of Devices</strong></td>
          <td><%= FzHttp.Devices.count(@user.id) %></td>
        </tr>

        <%= if @rules_path do %>
          <tr>
            <td><strong>Number of Rules</strong></td>
            <td><a href={"#{@rules_path}"}><%= FzHttp.Rules.count(@user.id) %></a></td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end
end
