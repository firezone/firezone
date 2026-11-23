defmodule PortalWeb.Settings.Profile do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Actor.Preferences
  alias __MODULE__.Database

  @form_channels [:email]

  @start_page_options [
    %{value: "activity", label: "Activity", icon: "ri-pulse-line"},
    %{value: "access", label: "Access", icon: "ri-shield-keyhole-line"},
    %{value: "sites", label: "Sites", icon: "ri-map-pin-line"},
    %{value: "resources", label: "Resources", icon: "ri-server-line"},
    %{value: "groups", label: "Groups", icon: "ri-team-line"},
    %{value: "policies", label: "Policies", icon: "ri-shield-check-line"},
    %{value: "devices", label: "Devices", icon: "ri-computer-line"},
    %{value: "actors", label: "People", icon: "ri-user-line"}
  ]

  def mount(_params, _session, socket) do
    actor = socket.assigns.subject.actor
    actor = %{actor | preferences: actor.preferences || %Preferences{}}

    socket =
      assign(socket,
        page_title: "Your settings",
        actor: actor,
        connections: Portal.OAuth.list_grants(socket.assigns.subject),
        confirm_disconnect_id: nil,
        expanded_grant_id: nil,
        start_page_options: @start_page_options,
        form: to_form(build_changeset(actor)),
        notifications_form: to_form(%{}, as: :notifications),
        seats_warning_plan?: Portal.Billing.seats_warning_plan?(socket.assigns.account)
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <Page.page_header>
        <:title>
          <span class="flex items-center gap-3 min-w-0">
            <Core.avatar account={@account} actor={@subject.actor} class="w-9 h-9" />
            <span class="truncate">{@subject.actor.name}</span>
          </span>
        </:title>
        <:description>{@subject.actor.email}</:description>
      </Page.page_header>

      <div class="flex-1 overflow-y-auto px-6 pb-10">
        <div class="max-w-3xl space-y-8">
          <section id="preferences">
            <.eyebrow icon="ri-equalizer-line">Preferences</.eyebrow>
            <.form for={@form} phx-change="save" id="preferences-form">
              <.inputs_for :let={prefs} field={@form[:preferences]}>
                <.start_page_selector field={prefs[:start_page]} options={@start_page_options} />
              </.inputs_for>
            </.form>
          </section>

          <section id="notifications">
            <div class="flex items-baseline justify-between mb-3">
              <.eyebrow icon="ri-notification-3-line" class="mb-0">Notification</.eyebrow>
              <span class="text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
                Email
              </span>
            </div>
            <.form for={@notifications_form} phx-change="save_notifications" id="notifications-form">
              <table class="w-full text-sm border-t border-rule">
                <tbody>
                  <.notification_row
                    notification={:outdated_gateways}
                    preferences={@actor.preferences}
                    icon="ri-arrow-up-circle-line"
                    label="Gateway upgrade available"
                    description="A new Gateway version is available"
                  />
                  <.notification_row
                    notification={:seat_limit_warnings}
                    preferences={@actor.preferences}
                    icon="ri-user-star-line"
                    label="Seat limit warnings"
                    description="Your monthly active users near or reach the seats in your subscription"
                    disabled={not @seats_warning_plan?}
                    disabled_reason="Seat count warnings are sent on Business plans only."
                  />
                  <.notification_row
                    notification={:product_announcements}
                    preferences={@actor.preferences}
                    icon="ri-megaphone-line"
                    label="Product announcements"
                    description="A monthly summary of new features and improvements in Firezone"
                  />
                  <.notification_row
                    notification={:product_feedback_requests}
                    preferences={@actor.preferences}
                    icon="ri-feedback-line"
                    label="Product feedback requests"
                    description="Getting started help and requests for feedback on Firezone"
                  />
                </tbody>
              </table>
            </.form>
          </section>

          <section id="connected-apps">
            <.eyebrow icon="ri-plug-line">Connected apps</.eyebrow>
            <p :if={@connections == []} class="flex items-center gap-2 text-sm text-muted">
              <Core.icon name="ri-apps-line" class="w-4 h-4 text-faint" />
              No apps are connected to your account.
            </p>

            <ul :if={@connections != []} class="border-t border-rule">
              <li :for={grant <- @connections} class="relative py-4 border-b border-hair">
                <div class="flex items-start gap-3">
                  <Page.client_icon client={grant.oauth_client} class="w-10 h-10" />

                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-semibold text-fg truncate">
                      {grant.oauth_client.client_name}
                    </p>
                    <p class="flex items-center gap-1.5 mt-0.5">
                      <Core.icon name="ri-lock-line" class="w-3 h-3 text-fg shrink-0" />
                      <span class="text-xs font-mono text-fg break-all">
                        {Page.client_host(grant.oauth_client.client_id)}
                      </span>
                    </p>
                    <p class="text-xs text-muted mt-0.5 break-all">
                      {grant.oauth_client.client_id}
                    </p>
                    <p class="text-xs text-muted mt-0.5">
                      Connected <Core.relative_datetime datetime={grant.inserted_at} />
                    </p>
                  </div>

                  <Form.button
                    :if={@confirm_disconnect_id != grant.id}
                    style="danger"
                    size="xs"
                    icon="ri-link-unlink"
                    phx-click="confirm_disconnect"
                    phx-value-id={grant.id}
                  >
                    Disconnect
                  </Form.button>
                </div>

                <div
                  :if={@confirm_disconnect_id == grant.id}
                  class="absolute right-0 top-3 z-10 w-1/2 min-w-[18rem] border border-rule bg-bg shadow-lg px-3 py-2.5"
                >
                  <p class="text-xs font-semibold text-attn mb-1">
                    Disconnect {grant.oauth_client.client_name}?
                  </p>
                  <p class="text-xs text-muted mb-3">
                    It will lose access immediately and any tokens it holds stop working.
                  </p>
                  <div class="flex items-center gap-1.5">
                    <Form.button type="button" phx-click="cancel_disconnect" size="xs">
                      Cancel
                    </Form.button>
                    <Form.button
                      type="button"
                      phx-click="disconnect"
                      phx-value-id={grant.id}
                      style="danger"
                      size="xs"
                    >
                      Disconnect
                    </Form.button>
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="toggle_permissions"
                  phx-value-id={grant.id}
                  class="mt-3 ml-[52px] flex items-center gap-1 text-xs text-muted hover:text-fg transition-colors"
                >
                  <Core.icon name="ri-key-2-line" class="w-3.5 h-3.5" />
                  {permissions_summary(grant.scopes)}
                  <Core.icon
                    name={
                      if @expanded_grant_id == grant.id,
                        do: "ri-arrow-up-s-line",
                        else: "ri-arrow-down-s-line"
                    }
                    class="w-4 h-4"
                  />
                </button>

                <ul :if={@expanded_grant_id == grant.id} class="mt-2 ml-[52px] space-y-1.5">
                  <.granted_permission
                    :for={{entity, level} <- Portal.Scope.grouped(grant.scopes)}
                    entity={entity}
                    level={level}
                  />
                </ul>
              </li>
            </ul>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :class, :string, default: "mb-3"
  slot :inner_block, required: true

  defp eyebrow(assigns) do
    ~H"""
    <h2 class={[
      "flex items-center gap-1.5 text-[11px] font-semibold tracking-[.12em] uppercase text-muted",
      @class
    ]}>
      <Core.icon name={@icon} class="w-3.5 h-3.5" />
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp permissions_summary(scopes) do
    case length(Portal.Scope.grouped(scopes)) do
      1 -> "1 permission granted"
      count -> "#{count} permissions granted"
    end
  end

  attr :entity, :atom, required: true
  attr :level, :atom, required: true

  defp granted_permission(assigns) do
    ~H"""
    <li class="flex items-baseline gap-2">
      <Core.badge size="xs" type={(@level == :write && "success") || "neutral"} class="uppercase">
        {@level}
      </Core.badge>
      <span class="min-w-0">
        <span class="text-xs text-fg">{Portal.Scope.label(@entity)}</span>
        <span class="text-xs text-muted"> - {Portal.Scope.description(@entity)}</span>
      </span>
    </li>
    """
  end

  attr :notification, :atom, required: true
  attr :preferences, :any, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil

  defp notification_row(assigns) do
    assigns =
      assign(assigns,
        id: "notifications_#{assigns.notification}_email",
        name: "notifications[#{assigns.notification}][email]",
        checked:
          not assigns.disabled and
            :email in Preferences.channels(assigns.preferences, assigns.notification)
      )

    ~H"""
    <tr class="border-b border-hair">
      <td class="pr-3 py-3 align-middle">
        <div class="flex items-start gap-2.5">
          <Core.icon name={@icon} class="w-4 h-4 mt-0.5 shrink-0 text-muted" />
          <div>
            <div class="text-sm font-medium text-fg">{@label}</div>
            <div class="text-xs text-muted mt-0.5">{@description}</div>
          </div>
        </div>
      </td>
      <td class="pl-3 py-3 align-middle">
        <span class="flex justify-end">
          <Core.popover :if={@disabled} placement="left" class="flex">
            <:target>
              <Core.toggle id={@id} checked={false} disabled />
            </:target>
            <:content>{@disabled_reason}</:content>
          </Core.popover>
          <input :if={not @disabled} type="hidden" name={@name} value="false" />
          <Core.toggle :if={not @disabled} id={@id} name={@name} value="true" checked={@checked} />
        </span>
      </td>
    </tr>
    """
  end

  defp start_page_selector(assigns) do
    ~H"""
    <div>
      <p class="text-sm font-medium text-fg mb-0.5">Start page</p>
      <p class="text-xs text-muted mb-3">
        Choose which page to land on after signing in.
      </p>
      <div class="grid grid-cols-3 sm:grid-cols-6 border-t border-l border-rule">
        <.start_page_option :for={opt <- @options} field={@field} option={opt} />
      </div>
    </div>
    """
  end

  defp start_page_option(assigns) do
    assigns =
      assign(assigns, :selected, to_string(assigns.field.value) == assigns.option.value)

    ~H"""
    <label class={[
      "flex flex-col items-center gap-2 px-3 py-3 border-r border-b border-rule cursor-pointer transition-colors",
      @selected && "bg-fg text-bg",
      not @selected && "text-muted hover:bg-hover hover:text-fg"
    ]}>
      <input
        type="radio"
        name={@field.name}
        value={@option.value}
        checked={@selected}
        class="sr-only"
      />
      <Core.icon name={@option.icon} class="w-5 h-5" />
      <span class="text-xs font-medium">{@option.label}</span>
    </label>
    """
  end

  # Only the notifications whose channels changed are written, so the others
  # stay unset and keep following the defaults.
  defp notifications_changeset(actor, params, seats_warning_plan?) do
    notifications =
      if seats_warning_plan? do
        Preferences.notifications()
      else
        Preferences.notifications() -- [:seat_limit_warnings]
      end

    changes =
      for notification <- notifications,
          %{} = channel_params <- [params[Atom.to_string(notification)]],
          current = Preferences.channels(actor.preferences, notification),
          channels = apply_channel_params(current, channel_params),
          channels != current,
          into: %{},
          do: {notification, channels}

    if changes == %{} do
      change(actor)
    else
      put_notification_channels(actor, changes)
    end
  end

  defp put_notification_channels(actor, changes) do
    actor
    |> cast(%{preferences: %{notifications: changes}}, [])
    |> cast_embed(:preferences,
      with: fn preferences, attrs ->
        (preferences || %Preferences{})
        |> cast(attrs, [])
        |> cast_embed(:notifications,
          with: fn notifications, attrs ->
            cast(notifications || %Preferences.Notifications{}, attrs, Map.keys(changes))
          end
        )
      end
    )
  end

  defp apply_channel_params(channels, channel_params) do
    Enum.reduce(@form_channels, channels, fn channel, channels ->
      case channel_params[Atom.to_string(channel)] do
        "true" -> Enum.uniq(channels ++ [channel])
        "false" -> channels -- [channel]
        _other -> channels
      end
    end)
  end

  defp build_changeset(actor, attrs \\ %{}) do
    actor
    |> cast(attrs, [])
    |> cast_embed(:preferences, with: &Preferences.changeset/2)
  end

  def handle_event("toggle_permissions", %{"id" => id}, socket) do
    expanded = if socket.assigns.expanded_grant_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_grant_id: expanded)}
  end

  def handle_event("confirm_disconnect", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_disconnect_id: id)}
  end

  def handle_event("cancel_disconnect", _params, socket) do
    {:noreply, assign(socket, confirm_disconnect_id: nil)}
  end

  def handle_event("disconnect", %{"id" => id}, socket) do
    {_count, _} = Portal.OAuth.delete_grant(id, socket.assigns.subject)

    socket =
      socket
      |> assign(
        connections: Portal.OAuth.list_grants(socket.assigns.subject),
        confirm_disconnect_id: nil
      )
      |> put_flash(:success, "The app was disconnected.")

    {:noreply, socket}
  end

  def handle_event("save", %{"actor" => attrs}, socket) do
    socket.assigns.actor
    |> build_changeset(attrs)
    |> save_preferences(socket)
  end

  def handle_event("save_notifications", %{"notifications" => params}, socket) do
    socket.assigns.actor
    |> notifications_changeset(params, socket.assigns.seats_warning_plan?)
    |> save_preferences(socket, "Notification preferences saved.")
  end

  defp save_preferences(changeset, socket, success_message \\ nil) do
    case Database.update(changeset, socket.assigns.subject) do
      {:ok, updated_actor} ->
        updated_actor = %{
          updated_actor
          | preferences: updated_actor.preferences || %Preferences{}
        }

        socket =
          socket
          |> assign(actor: updated_actor, form: to_form(build_changeset(updated_actor)))
          |> maybe_put_success_flash(success_message)

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  defp maybe_put_success_flash(socket, nil), do: socket
  defp maybe_put_success_flash(socket, message), do: put_flash(socket, :success, message)

  defmodule Database do
    alias Portal.Safe

    @spec update(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Portal.Actor.t()} | {:error, Ecto.Changeset.t()}
    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
