defmodule PortalWeb.Settings.Notifications do
  use PortalWeb, :live_view
  alias __MODULE__.Database

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Notifications",
        form: to_form(build_changeset(socket.assigns.account))
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <div class="flex-1 overflow-y-auto p-6">
        <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-4">
          Email Notifications
        </h3>

        <.form for={@form} phx-change="save" id="notifications-form" class="max-w-2xl">
          <.inputs_for :let={config} field={@form[:config]}>
            <.inputs_for :let={notifications} field={config[:notifications]}>
              <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] divide-y divide-[var(--border)]">
                <.inputs_for :let={outdated_gateway} field={notifications[:outdated_gateway]}>
                  <.notification_row
                    label="Gateway Upgrade Available"
                    description="Receive an email when a new gateway version is available"
                    field={outdated_gateway[:enabled]}
                  />
                </.inputs_for>
              </div>
            </.inputs_for>
          </.inputs_for>
        </.form>
      </div>
    </div>
    """
  end

  defp notification_row(assigns) do
    assigns = assign_new(assigns, :description, fn -> nil end)

    checked =
      Phoenix.HTML.Form.normalize_value("checkbox", assigns.field.value)

    assigns = assign(assigns, :checked, checked)

    ~H"""
    <div class="flex items-center justify-between px-4 py-3.5 gap-6">
      <div class="min-w-0">
        <p class="text-sm font-medium text-[var(--text-primary)]">{@label}</p>
        <p :if={@description} class="text-xs text-[var(--text-tertiary)] mt-0.5">{@description}</p>
      </div>
      <label class="inline-flex items-center shrink-0 cursor-pointer">
        <input type="hidden" name={@field.name} value="false" />
        <input
          type="checkbox"
          id={@field.id}
          name={@field.name}
          value="true"
          checked={@checked}
          class="sr-only"
        />
        <div class={[
          "w-9 h-5 rounded-full border transition-colors flex items-center px-0.5",
          @checked && "bg-[var(--brand)] border-[var(--brand)]",
          not @checked && "bg-[var(--control-bg)] border-[var(--control-border)]"
        ]}>
          <span class={[
            "w-4 h-4 bg-white rounded-full shadow-sm transition-transform",
            @checked && "translate-x-4",
            not @checked && "translate-x-0"
          ]}>
          </span>
        </div>
      </label>
    </div>
    """
  end

  defp build_changeset(account, attrs \\ %{}) do
    import Ecto.Changeset

    account
    |> cast(attrs, [])
    |> cast_embed(:config)
  end

  def handle_event("save", %{"account" => attrs}, socket) do
    case update_notifications(socket.assigns.account, attrs, socket.assigns.subject) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:success, "Notification preferences saved.")
         |> assign(account: account, form: to_form(build_changeset(account)))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  defp update_notifications(account, attrs, subject) do
    account
    |> build_changeset(attrs)
    |> Database.update(subject)
  end

  defmodule Database do
    alias Portal.Safe

    def update(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end
  end
end
