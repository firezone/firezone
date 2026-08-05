defmodule PortalWeb.Settings.DeviceIntegrations do
  use PortalWeb, :live_view

  import Ecto.Changeset

  alias Portal.{DeviceIntegration, Intune, PubSub}
  alias __MODULE__.Database

  require Logger

  @form_fields ~w[name]a
  @programmatic_fields ~w[tenant_id is_verified]a

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.subject.account.id, :device_inventory)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Device Inventory",
       trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?(),
       verification_error: nil,
       active_verification: nil,
       verifying: false
     )
     |> init()}
  end

  def handle_params(_params, _url, %{assigns: %{live_action: :new}} = socket) do
    if Enum.any?(socket.assigns.integrations) do
      {:noreply,
       socket
       |> put_flash(:error, "Only one device inventory integration can be configured at a time.")
       |> push_patch(to: index_path(socket))}
    else
      form =
        %Intune.Integration{}
        |> integration_changeset(%{})
        |> to_form()

      {:noreply,
       assign(socket,
         integration: nil,
         form: form,
         verification_error: nil,
         active_verification: nil,
         verifying: false
       )}
    end
  end

  def handle_params(%{"id" => id}, _url, %{assigns: %{live_action: :edit}} = socket) do
    integration = Database.get_integration!(id, socket.assigns.subject)

    {:noreply,
     assign(socket,
       integration: integration,
       form: to_form(integration_changeset(integration, %{})),
       verification_error: nil,
       active_verification: nil,
       verifying: false
     )}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     assign(socket,
       integration: nil,
       form: nil,
       verification_error: nil,
       active_verification: nil,
       verifying: false
     )}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: index_path(socket))}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket))}
  end

  def handle_event("handle_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"integration" => attrs}, socket) do
    changeset = socket.assigns.form.source

    attrs =
      Enum.reduce(@programmatic_fields, attrs, fn field, attrs ->
        case get_field(changeset, field) do
          nil -> attrs
          value -> Map.put(attrs, Atom.to_string(field), value)
        end
      end)

    base =
      if socket.assigns.live_action == :edit,
        do: changeset.data,
        else: apply_changes(changeset)

    changeset =
      base
      |> integration_changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("start_verification", _params, socket) do
    with {:ok, %{config: config}} <-
           PortalWeb.OIDC.setup_verification("intune_device_integration", []),
         verification_ref = Ecto.UUID.generate(),
         lv_pid_string = self() |> :erlang.pid_to_list() |> to_string(),
         state_token <-
           PortalWeb.OIDC.sign_verification_state(
             lv_pid_string,
             PortalWeb.OIDC.verification_state_type("intune_device_integration"),
             %{verification_ref: verification_ref}
           ),
         {:ok, uri} <-
           PortalWeb.OIDC.build_verification_uri(
             "intune_device_integration",
             config,
             "",
             state_token
           ) do
      {:noreply,
       socket
       |> assign(
         active_verification: %{verification_ref: verification_ref},
         verification_error: nil,
         verifying: true
       )
       |> push_event("open_url", %{url: uri})}
    else
      {:error, reason} ->
        Logger.info("Failed to start Intune verification", reason: inspect(reason))

        {:noreply,
         assign(socket,
           verifying: false,
           verification_error: "Failed to start Microsoft admin consent. Please try again."
         )}
    end
  end

  def handle_event("reset_verification", _params, socket) do
    changeset = socket.assigns.form.source
    base = if socket.assigns.live_action == :edit, do: changeset.data, else: apply_changes(changeset)

    attrs =
      changeset.changes
      |> Map.drop([:tenant_id, :is_verified])
      |> Map.put(:tenant_id, nil)
      |> Map.put(:is_verified, false)

    {:noreply,
     assign(socket,
       form: to_form(integration_changeset(base, attrs)),
       verification_error: nil,
       active_verification: nil,
       verifying: false
     )}
  end

  def handle_event(
        "submit",
        %{"integration" => attrs},
        %{assigns: %{live_action: :new}} = socket
      ) do
    changeset =
      socket
      |> submitted_changeset(attrs)
      |> put_device_integration_assoc(socket)

    changeset
    |> Database.insert_integration(socket.assigns.subject)
    |> handle_submit(socket)
  end

  def handle_event(
        "submit",
        %{"integration" => attrs},
        %{assigns: %{live_action: :edit}} = socket
      ) do
    socket
    |> submitted_changeset(attrs)
    |> Database.update_integration(socket.assigns.subject)
    |> handle_submit(socket)
  end

  def handle_event("sync", %{"id" => id}, socket) do
    case Oban.insert(Intune.Sync.new(%{"device_integration_id" => id})) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :success, "Device inventory sync queued.")}

      {:error, reason} ->
        Logger.info("Failed to queue Intune device inventory sync", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Could not queue device inventory sync.")}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    integration = Database.get_integration!(id, socket.assigns.subject)

    changeset =
      Ecto.Changeset.change(integration, %{
        is_disabled: not integration.is_disabled,
        disabled_reason: if(integration.is_disabled, do: nil, else: "Disabled by admin")
      })

    case Database.update_integration(changeset, socket.assigns.subject) do
      {:ok, _integration} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(
           :success,
           "Device inventory integration #{if(integration.is_disabled, do: "enabled", else: "disabled")}."
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the integration.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    integration = Database.get_integration!(id, socket.assigns.subject)

    case Database.delete_integration(integration, socket.assigns.subject) do
      {:ok, _integration} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Device inventory integration deleted.")
         |> push_patch(to: index_path(socket))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete the integration.")}
    end
  end

  def handle_info(
        {:intune_device_integration_complete, tenant_id, verification_ref, ack_to},
        socket
      ) do
    if active_verification?(socket, verification_ref) do
      changeset = socket.assigns.form.source

      attrs =
        changeset.changes
        |> Map.put(:tenant_id, tenant_id)
        |> Map.put(:is_verified, true)

      maybe_send_verification_ack(ack_to)

      {:noreply,
       assign(socket,
         form: to_form(integration_changeset(changeset.data, attrs)),
         active_verification: nil,
         verification_error: nil,
         verifying: false
       )}
    else
      maybe_send_verification_ack(ack_to)
      {:noreply, socket}
    end
  end

  def handle_info({:verification_failed, reason, verification_ref}, socket) do
    if active_verification?(socket, verification_ref) do
      {:noreply,
       assign(socket,
         active_verification: nil,
         verifying: false,
         verification_error: reason
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:device_inventory_changed, socket), do: {:noreply, init(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav
        account={@account}
        current_path={@current_path}
        trust_anchors_enabled?={@trust_anchors_enabled?}
      />

      <div class="flex-1 flex flex-col overflow-hidden">
        <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
          <div class="flex items-center gap-2">
            <h2 class="text-xs font-semibold text-heading">Device Integrations</h2>
            <span class="text-xs text-subtle tabular-nums">{length(@integrations)}</span>
          </div>
          <.link
            :if={Enum.empty?(@integrations)}
            patch={~p"/#{@account}/settings/device_integrations/intune/new"}
            class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
          >
            <.icon name="ri-add-line" class="w-3 h-3" /> Add Device Integration
          </.link>
        </div>

        <div class="flex-1 overflow-auto">
          <div :if={Enum.empty?(@integrations)} class="flex flex-col items-center justify-center h-full gap-3 text-subtle">
            <.icon name="ri-device-line" class="w-10 h-10" />
            <div class="text-center">
              <p class="text-sm text-heading">No device inventory integration configured.</p>
              <p class="mt-1 text-xs text-subtle">
                Connect Microsoft Intune to inventory devices before they connect to Firezone.
              </p>
            </div>
          </div>

          <table :if={not Enum.empty?(@integrations)} class="w-full text-sm border-collapse">
            <thead class="sticky top-0 z-10 bg-raised">
              <tr class="border-b border-border-strong">
                <.inventory_header>Integration</.inventory_header>
                <.inventory_header>Status</.inventory_header>
                <.inventory_header>Tenant</.inventory_header>
                <.inventory_header>Devices</.inventory_header>
                <.inventory_header>Last Synced</.inventory_header>
                <th class="px-6 py-2.5 w-64"></th>
              </tr>
            </thead>
            <tbody>
              <.integration_row :for={integration <- @integrations} account={@account} integration={integration} />
            </tbody>
          </table>
        </div>
      </div>

      <div
        id="device-integration-panel"
        class={[
          "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
          "bg-elevated border-l border-border-strong shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
          "transition-transform duration-200 ease-in-out",
          (@live_action in [:new, :edit] && "translate-x-0") || "translate-x-full"
        ]}
        phx-window-keydown="handle_keydown"
        phx-key="Escape"
      >
        <div :if={@live_action in [:new, :edit] and @form} class="flex flex-col h-full overflow-hidden">
          <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
            <div class="flex items-center gap-2">
              <.icon name="ri-microsoft-fill" class="w-5 h-5 text-accent" />
              <h2 class="text-sm font-semibold text-heading">
                {if @live_action == :new, do: "Add Microsoft Intune", else: "Edit Microsoft Intune"}
              </h2>
            </div>
            <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
          </div>

          <div class="flex-1 overflow-y-auto px-5 py-4">
            <.integration_form
              form={@form}
              verification_error={@verification_error}
              verifying={@verifying}
            />
          </div>

          <div class="shrink-0 flex items-center justify-between gap-2 px-5 py-4 border-t border-border">
            <.button
              :if={@live_action == :edit}
              type="button"
              style="danger"
              phx-click="delete"
              phx-value-id={@integration.id}
              data-confirm="Delete this integration and all synced Intune devices?"
            >
              Delete
            </.button>
            <div class="ml-auto flex items-center gap-2">
              <.button type="button" phx-click="close_panel">Cancel</.button>
              <.button form="device-integration-form" type="submit" style="primary" disabled={not @form.source.valid?}>
                {if @live_action == :new, do: "Create", else: "Save"}
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :integration, :map, required: true
  attr :account, :map, required: true

  defp integration_row(assigns) do
    ~H"""
    <tr class="border-b border-border hover:bg-raised/50 transition-colors">
      <td class="px-6 py-3">
        <div class="flex items-center gap-2">
          <.icon name="ri-microsoft-fill" class="w-4 h-4 text-accent" />
          <div>
            <p class="text-xs font-medium text-heading">{@integration.name}</p>
            <p class="text-[10px] text-subtle">Microsoft Intune</p>
          </div>
        </div>
      </td>
      <td class="px-6 py-3"><.integration_status integration={@integration} /></td>
      <td class="px-6 py-3 font-mono text-xs text-body">{@integration.tenant_id}</td>
      <td class="px-6 py-3 text-xs tabular-nums text-body">{@integration.devices_count}</td>
      <td class="px-6 py-3 text-xs text-body">
        <.relative_datetime :if={@integration.synced_at} datetime={@integration.synced_at} />
        <span :if={is_nil(@integration.synced_at)} class="text-subtle">Never</span>
      </td>
      <td class="px-6 py-3">
        <div class="flex items-center justify-end gap-2">
          <.button type="button" phx-click="sync" phx-value-id={@integration.id} disabled={@integration.is_disabled}>
            Sync now
          </.button>
          <.button type="button" phx-click="toggle" phx-value-id={@integration.id}>
            {if @integration.is_disabled, do: "Enable", else: "Disable"}
          </.button>
          <.link
            patch={~p"/#{@account}/settings/device_integrations/intune/#{@integration.id}/edit"}
            class="inline-flex items-center justify-center w-7 h-7 rounded border border-border-strong text-body hover:text-heading hover:border-border-emphasis"
            title="Edit"
          >
            <.icon name="ri-pencil-line" class="w-3.5 h-3.5" />
          </.link>
        </div>
      </td>
    </tr>
    """
  end

  attr :integration, :map, required: true

  defp integration_status(assigns) do
    {label, class} =
      cond do
        assigns.integration.is_disabled -> {"Disabled", "bg-neutral-100 text-neutral-700"}
        assigns.integration.errored_at -> {"Sync error", "bg-danger-light text-danger"}
        true -> {"Active", "bg-success-light text-success"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span class={["inline-flex rounded-full px-2 py-0.5 text-[10px] font-medium", @class]}>
      {@label}
    </span>
    """
  end

  attr :form, :map, required: true
  attr :verification_error, :string, default: nil
  attr :verifying, :boolean, default: false

  defp integration_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="device-integration-form"
      as={:integration}
      phx-change="validate"
      phx-submit="submit"
      class="space-y-5"
    >
      <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />

      <div class="rounded border border-border bg-surface p-4 space-y-3">
        <div class="flex items-start justify-between gap-4">
          <div>
            <p class="text-xs font-medium text-heading">Microsoft admin consent</p>
            <p class="mt-1 text-xs text-subtle">
              Grants read-only access to Intune managed devices using the Firezone app registration.
            </p>
          </div>
          <.integration_verification_status form={@form} />
        </div>

        <div :if={get_field(@form.source, :is_verified)} class="flex items-center justify-between border-t border-border pt-3">
          <div>
            <p class="text-[10px] uppercase tracking-widest text-subtle">Tenant ID</p>
            <p class="mt-0.5 font-mono text-xs text-heading">{get_field(@form.source, :tenant_id)}</p>
          </div>
          <button type="button" phx-click="reset_verification" class="text-xs text-body underline hover:text-heading">
            Reverify
          </button>
        </div>

        <.button
          :if={not get_field(@form.source, :is_verified)}
          id="intune-admin-consent-button"
          type="button"
          style="primary"
          icon="ri-external-link-line"
          phx-click="start_verification"
          phx-hook="OpenURL"
          disabled={@verifying}
        >
          {if @verifying, do: "Waiting for Microsoft…", else: "Grant admin consent"}
        </.button>

        <p :if={@verification_error} class="text-xs text-danger">{@verification_error}</p>
      </div>

    </.form>
    """
  end

  attr :form, :map, required: true

  defp integration_verification_status(assigns) do
    assigns = assign(assigns, :verified?, get_field(assigns.form.source, :is_verified) == true)

    ~H"""
    <span class={[
      "inline-flex rounded-full px-2 py-0.5 text-[10px] font-medium",
      @verified? && "bg-success-light text-success",
      not @verified? && "bg-warning-light text-warning"
    ]}>
      {if @verified?, do: "Verified", else: "Consent required"}
    </span>
    """
  end

  slot :inner_block, required: true

  defp inventory_header(assigns) do
    ~H"""
    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle">
      {render_slot(@inner_block)}
    </th>
    """
  end

  defp integration_changeset(integration, attrs) do
    integration
    |> cast(attrs, @form_fields ++ @programmatic_fields ++ ~w[is_disabled disabled_reason]a)
    |> Intune.Integration.changeset()
  end

  defp submitted_changeset(socket, attrs) do
    source = socket.assigns.form.source

    attrs =
      Enum.reduce(@programmatic_fields, attrs, fn field, attrs ->
        Map.put(attrs, Atom.to_string(field), get_field(source, field))
      end)

    integration_changeset(source.data, attrs)
  end

  defp put_device_integration_assoc(changeset, socket) do
    id = Ecto.UUID.generate()

    parent_changeset =
      %DeviceIntegration{}
      |> Ecto.Changeset.change(%{
        id: id,
        account_id: socket.assigns.subject.account.id,
        type: :intune
      })

    changeset
    |> put_change(:id, id)
    |> put_assoc(:device_integration, parent_changeset)
  end

  defp handle_submit({:ok, integration}, socket) do
    if socket.assigns.live_action == :new do
      _ = Oban.insert(Intune.Sync.new(%{"device_integration_id" => integration.id}))
    end

    {:noreply,
     socket
     |> init()
     |> put_flash(:success, "Device inventory integration saved.")
     |> push_patch(to: index_path(socket))}
  end

  defp handle_submit({:error, changeset}, socket) do
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  defp init(socket) do
    assign(socket, integrations: Database.list_integrations(socket.assigns.subject))
  end

  defp active_verification?(socket, verification_ref) do
    match?(
      %{verification_ref: ^verification_ref} when is_binary(verification_ref),
      socket.assigns.active_verification
    )
  end

  defp maybe_send_verification_ack({pid, ref}) when is_pid(pid) do
    send(pid, {:verification_ack, ref})
  end

  defp maybe_send_verification_ack(_), do: :ok

  defp index_path(socket), do: ~p"/#{socket.assigns.account}/settings/device_integrations"

  defmodule Database do
    import Ecto.Query

    alias Portal.{DeviceIntegration, Intune, Safe}

    def list_integrations(subject) do
      device_counts =
        from(d in Intune.Device,
          group_by: d.device_integration_id,
          select: {d.device_integration_id, count(d.id)}
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Map.new()

      Intune.Integration
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Enum.map(&Map.put(&1, :devices_count, Map.get(device_counts, &1.id, 0)))
    end

    def get_integration!(id, subject) do
      from(i in Intune.Integration, where: i.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def insert_integration(changeset, subject) do
      changeset |> Safe.scoped(subject) |> Safe.insert()
    end

    def update_integration(changeset, subject) do
      changeset |> Safe.scoped(subject) |> Safe.update()
    end

    def delete_integration(integration, subject) do
      from(i in DeviceIntegration, where: i.id == ^integration.id)
      |> Safe.scoped(subject)
      |> Safe.one!()
      |> Safe.scoped(subject)
      |> Safe.delete()
    end
  end
end
