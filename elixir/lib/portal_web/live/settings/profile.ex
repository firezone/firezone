defmodule PortalWeb.Settings.Profile do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Actor.Preferences
  alias __MODULE__.Database

  @start_page_options [
    %{value: "sites", label: "Sites", icon: "ri-global-line"},
    %{value: "resources", label: "Resources", icon: "ri-server-line"},
    %{value: "groups", label: "Groups", icon: "ri-team-line"},
    %{value: "policies", label: "Policies", icon: "ri-shield-check-line"},
    %{value: "devices", label: "Devices", icon: "ri-computer-line"},
    %{value: "actors", label: "Actors", icon: "ri-user-line"}
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
        form: to_form(build_changeset(actor))
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Profile header --%>
      <div class="relative overflow-hidden px-6 pt-6 pb-5 border-b border-border">
        <div class="absolute inset-x-0 top-0 h-[2px] bg-brand opacity-50"></div>
        <div class="flex items-center gap-5">
          <.icon name="ri-user-line" class="shrink-0 w-16 h-16 text-brand" />
          <div class="flex-1 min-w-0">
            <h1 class="text-base font-semibold text-heading">{@subject.actor.name}</h1>
            <p class="mt-0.5 text-sm text-body">{@subject.actor.email}</p>
          </div>
        </div>
      </div>

      <%!-- Preferences content --%>
      <div class="flex-1 overflow-y-auto p-6">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-4">
          Preferences
        </h3>

        <.form for={@form} phx-change="save" id="preferences-form" class="max-w-2xl">
          <div class="rounded border border-border bg-raised divide-y divide-border">
            <.inputs_for :let={prefs} field={@form[:preferences]}>
              <.start_page_selector field={prefs[:start_page]} options={@start_page_options} />
            </.inputs_for>
          </div>
        </.form>

        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mt-8 mb-4">
          Connected apps
        </h3>

        <div class="max-w-2xl">
          <p :if={@connections == []} class="text-sm text-subtle">
            No apps are connected to your account.
          </p>

          <div
            :if={@connections != []}
            class="rounded border border-border bg-raised divide-y divide-border"
          >
            <div :for={grant <- @connections} class="relative px-4 py-3.5">
              <div class="flex items-start gap-3">
                <.client_icon client={grant.oauth_client} class="w-10 h-10" />

                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-heading truncate">
                    {grant.oauth_client.client_name}
                  </p>
                  <p class="flex items-center gap-1.5 mt-0.5">
                    <.icon name="ri-lock-line" class="w-3 h-3 text-brand shrink-0" />
                    <span class="text-xs font-mono text-body break-all">
                      {client_host(grant.oauth_client.client_id)}
                    </span>
                  </p>
                  <p class="text-xs text-subtle mt-0.5 break-all">
                    {grant.oauth_client.client_id}
                  </p>
                  <p class="text-xs text-subtle mt-0.5">
                    Connected <.relative_datetime datetime={grant.inserted_at} />
                  </p>
                </div>

                <.button
                  :if={@confirm_disconnect_id != grant.id}
                  style="danger"
                  size="xs"
                  phx-click="confirm_disconnect"
                  phx-value-id={grant.id}
                >
                  Disconnect
                </.button>
              </div>

              <%!-- Floated over the card rather than inserted into it, so opening
                    the confirmation does not move everything below it. --%>
              <div
                :if={@confirm_disconnect_id == grant.id}
                class="absolute right-3 top-3 z-10 w-1/2 min-w-[18rem] rounded-md border border-border bg-elevated shadow-lg overflow-hidden"
              >
                <div class="px-3 py-2.5 bg-error-light">
                  <p class="text-xs font-medium text-error mb-1">
                    Disconnect {grant.oauth_client.client_name}?
                  </p>
                  <p class="text-xs text-error/70 mb-3">
                    It will lose access immediately and any tokens it holds stop working.
                  </p>
                  <div class="flex items-center gap-1.5">
                    <.button type="button" phx-click="cancel_disconnect" size="xs">
                      Cancel
                    </.button>
                    <.button
                      type="button"
                      phx-click="disconnect"
                      phx-value-id={grant.id}
                      style="danger"
                      size="xs"
                    >
                      Disconnect
                    </.button>
                  </div>
                </div>
              </div>

              <button
                type="button"
                phx-click="toggle_permissions"
                phx-value-id={grant.id}
                class="mt-3 flex items-center gap-1 text-xs text-body hover:text-heading transition-colors"
              >
                {permissions_summary(grant.scopes)}
                <.icon
                  name={
                    if @expanded_grant_id == grant.id,
                      do: "ri-arrow-up-s-line",
                      else: "ri-arrow-down-s-line"
                  }
                  class="w-4 h-4"
                />
              </button>

              <ul :if={@expanded_grant_id == grant.id} class="mt-2 space-y-1.5">
                <.granted_permission
                  :for={{entity, level} <- Portal.Scope.grouped(grant.scopes)}
                  entity={entity}
                  level={level}
                />
              </ul>

            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp permissions_summary(scopes) do
    case length(Portal.Scope.grouped(scopes)) do
      1 -> "1 permission granted"
      count -> "#{count} permissions granted"
    end
  end

  # The same label and description the permission picker shows, so what was
  # granted reads exactly as it did when it was asked for.
  attr :entity, :atom, required: true
  attr :level, :atom, required: true

  defp granted_permission(assigns) do
    ~H"""
    <li class="flex items-baseline gap-2">
      <span class={[
        "shrink-0 px-1.5 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide",
        (@level == :write && "bg-brand-muted text-brand") || "bg-raised text-subtle"
      ]}>
        {@level}
      </span>
      <span class="min-w-0">
        <span class="text-xs text-heading">{Portal.Scope.label(@entity)}</span>
        <span class="text-xs text-subtle"> - {Portal.Scope.description(@entity)}</span>
      </span>
    </li>
    """
  end

  defp start_page_selector(assigns) do
    ~H"""
    <div class="px-4 py-3.5">
      <p class="text-sm font-medium text-heading mb-0.5">Start Page</p>
      <p class="text-xs text-subtle mb-3">
        Choose which page to land on after signing in.
      </p>
      <div class="grid grid-cols-3 gap-2 sm:grid-cols-6">
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
      "flex flex-col items-center gap-2 px-3 py-3 rounded border cursor-pointer transition-colors",
      @selected && "border-brand bg-brand-muted text-brand",
      not @selected &&
        "border-border hover:border-border-strong text-body"
    ]}>
      <input
        type="radio"
        name={@field.name}
        value={@option.value}
        checked={@selected}
        class="sr-only"
      />
      <.icon name={@option.icon} class="w-5 h-5" />
      <span class="text-xs font-medium">{@option.label}</span>
    </label>
    """
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
    actor = socket.assigns.actor

    case update_preferences(actor, attrs, socket.assigns.subject) do
      {:ok, updated_actor} ->
        updated_actor = %{
          updated_actor
          | preferences: updated_actor.preferences || %Preferences{}
        }

        socket =
          assign(socket, actor: updated_actor, form: to_form(build_changeset(updated_actor)))

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  defp update_preferences(actor, attrs, subject) do
    actor
    |> build_changeset(attrs)
    |> Database.update(subject)
  end

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
