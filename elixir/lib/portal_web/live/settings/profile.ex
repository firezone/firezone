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
    %{value: "clients", label: "Clients", icon: "ri-computer-line"},
    %{value: "actors", label: "Actors", icon: "ri-user-line"}
  ]

  def mount(_params, _session, socket) do
    actor = socket.assigns.subject.actor
    actor = %{actor | preferences: actor.preferences || %Preferences{}}

    socket =
      assign(socket,
        page_title: "Profile",
        actor: actor,
        start_page_options: @start_page_options,
        form: to_form(build_changeset(actor))
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Profile header --%>
      <div class="relative overflow-hidden px-6 pt-6 pb-5 border-b border-[var(--border)]">
        <div class="absolute inset-x-0 top-0 h-[2px] bg-[var(--brand)] opacity-50"></div>
        <div class="flex items-center gap-5">
          <.icon name="ri-user-line" class="shrink-0 w-16 h-16 text-[var(--brand)]" />
          <div class="flex-1 min-w-0">
            <h1 class="text-base font-semibold text-[var(--text-primary)]">{@subject.actor.name}</h1>
            <p class="mt-0.5 text-sm text-[var(--text-secondary)]">{@subject.actor.email}</p>
          </div>
        </div>
      </div>

      <%!-- Preferences content --%>
      <div class="flex-1 overflow-y-auto p-6">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-4">
          Preferences
        </h3>

        <.form for={@form} phx-change="save" id="preferences-form" class="max-w-2xl">
          <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] divide-y divide-[var(--border)]">
            <.inputs_for :let={prefs} field={@form[:preferences]}>
              <.start_page_selector field={prefs[:start_page]} options={@start_page_options} />
            </.inputs_for>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp start_page_selector(assigns) do
    ~H"""
    <div class="px-4 py-3.5">
      <p class="text-sm font-medium text-[var(--text-primary)] mb-0.5">Start Page</p>
      <p class="text-xs text-[var(--text-tertiary)] mb-3">
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
      @selected && "border-[var(--brand)] bg-[var(--brand-muted)] text-[var(--brand)]",
      not @selected &&
        "border-[var(--border)] hover:border-[var(--border-strong)] text-[var(--text-secondary)]"
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
