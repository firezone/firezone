defmodule PortalWeb.Settings.DevicePosture do
  use PortalWeb, :live_view

  import Ecto.Changeset

  alias Portal.{DeviceIntegration, Intune, PubSub}
  alias __MODULE__.Database

  require Logger

  @feature_disabled "Device posture is not enabled for your account."

  @form_fields ~w[name]a
  @programmatic_fields ~w[tenant_id is_verified]a

  def mount(_params, _session, socket) do
    if PortalWeb.NavigationComponents.device_posture_enabled?() do
      mount_enabled(socket)
    else
      {:ok,
       socket
       |> put_flash(:error, @feature_disabled)
       |> push_navigate(to: ~p"/#{socket.assigns.account}/settings/account")}
    end
  end

  defp mount_enabled(socket) do
    if connected?(socket) do
      :ok = PubSub.Changes.subscribe(socket.assigns.subject.account.id, :device_inventory)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Device Posture",
       trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?(),
       device_posture_enabled?: true,
       verification_error: nil,
       active_verification: nil,
       pending_verification: nil,
       verifying: false,
       open_integration_actions_id: nil
     )
     |> init()}
  end

  def handle_params(_params, _url, %{assigns: %{live_action: :new}} = socket) do
    cond do
      not account_feature_enabled?(socket) ->
        {:noreply, push_patch(socket, to: index_path(socket))}

      Enum.any?(socket.assigns.integrations) ->
        {:noreply,
         socket
         |> put_flash(:error, "Only one device inventory integration can be configured at a time.")
         |> push_patch(to: index_path(socket))}

      true ->
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
    if account_feature_enabled?(socket) do
      integration = Database.get_integration!(id, socket.assigns.subject)

      {:noreply,
       assign(socket,
         integration: integration,
         form: to_form(integration_changeset(integration, %{})),
         verification_error: nil,
         active_verification: nil,
         verifying: false
       )}
    else
      {:noreply, push_patch(socket, to: index_path(socket))}
    end
  end

  # Leaving the panel abandons any verification started from it, so the pending
  # verifier goes with it rather than staying live for a callback that no longer
  # has a form to land in.
  def handle_params(_params, _url, socket) do
    {:noreply,
     assign(socket,
       integration: nil,
       form: nil,
       verification_error: nil,
       active_verification: nil,
       pending_verification: nil,
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
         verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
         verification_ref = Ecto.UUID.generate(),
         lv_pid_string = PortalWeb.OIDC.serialize_pid(self()),
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
             verifier,
             state_token
           ) do
      verification = %{
        config: config,
        verifier: verifier,
        verification_ref: verification_ref
      }

      {:noreply,
       socket
       |> assign(
         active_verification: nil,
         pending_verification: verification,
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
    |> handle_submit(socket, true)
  end

  def handle_event(
        "submit",
        %{"integration" => attrs},
        %{assigns: %{live_action: :edit}} = socket
      ) do
    changeset =
      socket
      |> submitted_changeset(attrs)
      |> clear_sync_error()

    # Devices already stored belong to the old tenant, and one coming back from
    # a sync error has been stale for as long as it was disabled, so either way
    # waiting for the next scheduled run would show the wrong inventory.
    resync? =
      Map.has_key?(changeset.changes, :tenant_id) or
        get_change(changeset, :is_disabled) == false

    changeset
    |> Database.update_integration(socket.assigns.subject)
    |> handle_submit(socket, resync?)
  end

  def handle_event("toggle_integration_actions", %{"id" => id}, socket) do
    open = if socket.assigns.open_integration_actions_id == id, do: nil, else: id
    {:noreply, assign(socket, open_integration_actions_id: open)}
  end

  def handle_event("close_integration_actions", _params, socket) do
    {:noreply, assign(socket, open_integration_actions_id: nil)}
  end

  def handle_event("sync", %{"id" => id}, socket) do
    socket = assign(socket, open_integration_actions_id: nil)
    integration = Enum.find(socket.assigns.integrations, &(&1.id == id))

    cond do
      not account_feature_enabled?(socket) ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      is_nil(integration) ->
        {:noreply, put_flash(socket, :error, "Could not queue device inventory sync.")}

      true ->
        queue_sync(integration, socket)
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    socket = assign(socket, open_integration_actions_id: nil)
    integration = Database.get_integration!(id, socket.assigns.subject)

    changeset = toggle_changeset(integration, not integration.is_disabled)

    case Database.update_integration(changeset, socket.assigns.subject) do
      {:ok, _integration} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(
           :success,
           "Device inventory integration #{if(integration.is_disabled, do: "enabled", else: "disabled")}."
         )}

      {:error, :feature_disabled} ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      {:error, %Ecto.Changeset{errors: [{:is_verified, {message, _}} | _]}} ->
        {:noreply, put_flash(socket, :error, message)}

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

      {:error, :feature_disabled} ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete the integration.")}
    end
  end

  def handle_info({:peek_pending_verification, from}, socket) do
    send(from, {:pending_verification, socket.assigns[:pending_verification]})
    {:noreply, socket}
  end

  # The callback carries its verification reference so a stale one cannot
  # consume a newer pending verifier.
  def handle_info({:get_pending_verification, verification_ref, from}, socket) do
    case socket.assigns[:pending_verification] do
      %{verification_ref: ^verification_ref} = pending_verification ->
        send(from, {:pending_verification, pending_verification})

        {:noreply,
         assign(socket, pending_verification: nil, active_verification: pending_verification)}

      _pending_verification ->
        send(from, {:pending_verification, nil})
        {:noreply, socket}
    end
  end

  def handle_info({:get_pending_verification, from}, socket) do
    pending_verification = socket.assigns[:pending_verification]
    send(from, {:pending_verification, pending_verification})

    socket =
      case pending_verification do
        nil -> assign(socket, pending_verification: nil)
        pending -> assign(socket, pending_verification: nil, active_verification: pending)
      end

    {:noreply, socket}
  end

  def handle_info(
        {:intune_device_integration_complete, tenant_id, verification_ref, ack_to},
        socket
      ) do
    if active_verification?(socket, verification_ref) and socket.assigns.form do
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
        device_posture_enabled?={@device_posture_enabled?}
      />

      <%= if Portal.Account.device_posture_enabled?(@account) do %>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-semibold text-heading">Device Posture</h2>
              <span class="text-xs text-subtle tabular-nums">{length(@integrations)}</span>
            </div>
            <.link
              :if={Enum.empty?(@integrations)}
              patch={~p"/#{@account}/settings/device_posture/intune/new"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <.icon name="ri-add-line" class="w-3 h-3" /> Add Microsoft Intune
            </.link>
          </div>

          <div
            :if={not Enum.empty?(@integrations)}
            id="device-posture-summary"
            class="flex flex-wrap items-center gap-2 px-6 py-2.5 border-b border-border shrink-0"
          >
            <.dual_badge type="primary">
              <:left>{@devices_count}</:left>
              <:right>Devices synced</:right>
            </.dual_badge>
            <.dual_badge type="success">
              <:left>{@compliant_count}</:left>
              <:right>Compliant</:right>
            </.dual_badge>
            <.dual_badge type="danger">
              <:left>{@noncompliant_count}</:left>
              <:right>Not compliant</:right>
            </.dual_badge>
            <.dual_badge :if={@in_grace_period_count > 0} type="warning">
              <:left>{@in_grace_period_count}</:left>
              <:right>In grace period</:right>
            </.dual_badge>
          </div>

          <div class="flex-1 overflow-auto">
            <%= if Enum.empty?(@integrations) do %>
              <div class="flex flex-col items-center justify-center h-full gap-3 text-subtle">
                <p class="text-sm">No device posture provider configured.</p>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/intune/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add Microsoft Intune
                </.link>
              </div>
            <% else %>
              <table class="w-full text-sm border-collapse">
                <thead class="sticky top-0 z-10 bg-raised">
                  <tr class="border-b border-border-strong">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                      Integration
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Status
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-48">
                      Tenant
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Devices
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-40">
                      Last Synced
                    </th>
                    <th class="px-6 py-2.5 w-14"></th>
                  </tr>
                </thead>
                <tbody>
                  <.integration_row
                    :for={integration <- @integrations}
                    account={@account}
                    integration={integration}
                    open_actions_id={@open_integration_actions_id}
                  />
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
      <% else %>
        <.upgrade_splash account={@account} />
      <% end %>

      <div
        id="device-posture-panel"
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
              <.provider_icon provider="entra" size="sm" />
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
              <.button form="device-posture-form" type="submit" style="primary" disabled={not @form.source.valid?}>
                {if @live_action == :new, do: "Create", else: "Save"}
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :account, :any, required: true

  # Shown when the feature is on globally but not for this account, matching the
  # log sinks upgrade page: a blurred sample of the real table under a card.
  defp upgrade_splash(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col overflow-hidden">
      <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
        <div class="flex items-center gap-2">
          <h2 class="text-xs font-semibold text-heading">Device Posture</h2>
        </div>
      </div>

      <div class="flex-1 overflow-hidden relative">
        <div class="blur-xs pointer-events-none select-none opacity-60">
          <table class="w-full text-sm border-collapse">
            <thead class="bg-raised">
              <tr class="border-b border-border-strong">
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                  Integration
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                  Status
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-48">
                  Tenant
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                  Devices
                </th>
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-40">
                  Last Synced
                </th>
                <th class="px-6 py-2.5 w-14"></th>
              </tr>
            </thead>
            <tbody>
              <tr class="border-b border-border">
                <td class="px-6 py-3">
                  <div class="flex items-center gap-3">
                    <.provider_icon provider="entra" size="lg" />
                    <div class="min-w-0">
                      <span class="text-sm font-medium text-heading truncate block">
                        Microsoft Intune
                      </span>
                      <span class="text-xs text-subtle">Microsoft Intune</span>
                    </div>
                  </div>
                </td>
                <td class="px-6 py-3 w-28">
                  <.status_badge style={:success}>Active</.status_badge>
                </td>
                <td class="px-6 py-3 w-48">
                  <span class="text-sm text-body font-mono truncate block">
                    contoso.onmicrosoft.com
                  </span>
                </td>
                <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">1,284</td>
                <td class="px-6 py-3 w-40"><span class="text-xs text-body">2 hours ago</span></td>
                <td class="px-6 py-3 w-14"></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="absolute inset-0 flex items-end justify-center pb-[20%]">
          <div class="flex flex-col items-center gap-3 bg-elevated border border-border rounded-lg shadow-lg px-8 py-6 text-subtle">
            <.icon name="ri-device-line" class="w-8 h-8" />
            <div class="flex flex-col items-center gap-1 text-center">
              <p class="text-sm font-medium text-heading">
                Inventory Your Managed Devices
              </p>
              <p class="text-xs">
                Integrate with MDM and EDR solutions to provide device telemetry to use in policy conditions
              </p>
            </div>
            <.button
              style="primary"
              icon="ri-sparkling-fill"
              navigate={~p"/#{@account}/settings/account"}
            >
              Upgrade to Unlock
            </.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :integration, :map, required: true
  attr :account, :map, required: true
  attr :open_actions_id, :string, default: nil

  defp integration_row(assigns) do
    ~H"""
    <tr class="border-b border-border hover:bg-raised">
      <td class="px-6 py-3">
        <div class="flex items-center gap-3">
          <.provider_icon provider="entra" size="lg" />
          <div class="min-w-0">
            <span class="text-sm font-medium text-heading truncate block" title={@integration.name}>
              {@integration.name}
            </span>
            <span class="text-xs text-subtle">Microsoft Intune</span>
          </div>
        </div>
      </td>
      <td class="px-6 py-3 w-28">
        <.integration_status integration={@integration} />
      </td>
      <td class="px-6 py-3 w-48">
        <span class="text-sm text-body font-mono truncate block">
          {@integration.tenant_id || "—"}
        </span>
      </td>
      <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">
        {@integration.devices_count}
      </td>
      <td class="px-6 py-3 w-40">
        <span :if={@integration.synced_at} class="text-xs text-body">
          <.relative_datetime datetime={@integration.synced_at} />
        </span>
        <span :if={is_nil(@integration.synced_at)} class="text-xs text-subtle">Never</span>
      </td>
      <td class="px-6 py-3 w-14">
        <div class="flex justify-end">
          <.actions_dropdown
            open={@open_actions_id == @integration.id}
            close_event="close_integration_actions"
            phx-click="toggle_integration_actions"
            phx-value-id={@integration.id}
          >
            <.link
              patch={~p"/#{@account}/settings/device_posture/intune/#{@integration.id}/edit"}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
            >
              <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
            </.link>
            <button
              type="button"
              phx-click="sync"
              phx-value-id={@integration.id}
              disabled={@integration.is_disabled}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <.icon name="ri-loop-left-line" class="w-3.5 h-3.5 shrink-0" /> Sync Now
            </button>
            <div class="my-1 border-t border-border"></div>
            <button
              type="button"
              phx-click="toggle"
              phx-value-id={@integration.id}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
            >
              <.icon
                name={if @integration.is_disabled, do: "ri-play-line", else: "ri-pause-line"}
                class="w-3.5 h-3.5 shrink-0"
              />
              {if @integration.is_disabled, do: "Enable", else: "Disable"}
            </button>
          </.actions_dropdown>
        </div>
      </td>
    </tr>
    """
  end

  attr :integration, :map, required: true

  defp integration_status(assigns) do
    {style, label} =
      cond do
        assigns.integration.is_disabled and assigns.integration.disabled_reason == "Sync error" ->
          {:danger, "Error"}

        assigns.integration.is_disabled ->
          {:neutral, "Disabled"}

        assigns.integration.errored_at ->
          {:warning, "Warning"}

        assigns.integration.is_verified ->
          {:success, "Active"}

        true ->
          {:neutral, "Unverified"}
      end

    assigns = assign(assigns, style: style, label: label)

    ~H"""
    <.status_badge style={@style}>{@label}</.status_badge>
    """
  end

  attr :form, :map, required: true
  attr :verification_error, :string, default: nil
  attr :verifying, :boolean, default: false

  defp integration_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="device-posture-form"
      as={:integration}
      phx-change="validate"
      phx-submit="submit"
      class="space-y-5"
    >
      <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />

      <div id="intune-verification" class="p-4 border border-border bg-raised rounded">
        <.flash :if={@verification_error} kind={:error}>
          {@verification_error}
        </.flash>
        <div class="flex items-center justify-between">
          <div class="flex-1">
            <h3 class="text-sm font-semibold text-heading">Integration Verification</h3>
            <p class="mt-1 text-xs text-body">
              {integration_verification_help_text(@form)}
            </p>
          </div>
          <div class="ml-4">
            <.integration_verification_status form={@form} verifying={@verifying} />
          </div>
        </div>

        <div class="mt-4 pt-4 border-t border-border space-y-3">
          <div class="flex justify-between items-center">
            <label class="text-xs font-medium text-body">Tenant ID</label>
            <div class="text-right">
              <p id="intune-tenant-id" class="text-xs font-semibold text-heading">
                {integration_verification_tenant_id(@form)}
              </p>
            </div>
          </div>
          <.reset_integration_verification_button form={@form} />
        </div>
      </div>
    </.form>
    """
  end

  attr :form, :map, required: true
  attr :verifying, :boolean, required: true

  defp integration_verification_status(assigns) do
    assigns = assign(assigns, :verified?, get_field(assigns.form.source, :is_verified) == true)

    ~H"""
    <div id="intune-admin-consent-open-url" phx-hook="OpenURL">
      <div
        :if={@verified?}
        id="intune-verification-status"
        class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-sm"
      >
        <.icon name="ri-checkbox-circle-line" class="h-5 w-5 mr-2" />
        <span class="font-medium">Verified</span>
      </div>
      <.button
        :if={not @verified? and not @verifying}
        id="intune-admin-consent-button"
        type="button"
        style="primary"
        icon="ri-external-link-line"
        phx-click="start_verification"
      >
        Verify Now
      </.button>
      <.button :if={not @verified? and @verifying} type="button" style="primary" disabled>
        Verifying...
      </.button>
    </div>
    """
  end

  defp integration_verification_help_text(form) do
    if get_field(form.source, :is_verified) do
      "This integration has been successfully verified."
    else
      "Grant Microsoft admin consent to verify the Intune integration."
    end
  end

  defp integration_verification_tenant_id(form) do
    if get_field(form.source, :is_verified) do
      get_field(form.source, :tenant_id)
    else
      "Awaiting verification..."
    end
  end

  attr :form, :map, required: true

  defp reset_integration_verification_button(assigns) do
    ~H"""
    <div :if={get_field(@form.source, :is_verified)} class="text-right">
      <button
        type="button"
        phx-click="reset_verification"
        class="text-xs text-body hover:text-heading underline"
        title="Reset verification to grant admin consent again"
      >
        Reset verification
      </button>
    </div>
    """
  end

  # Admin consent is what proves the tenant granted us access, so the form
  # refuses to save until it succeeded. The sync still needs to clear the flag
  # when consent is later revoked, so this stays out of the base changeset.
  defp integration_changeset(integration, attrs) do
    integration
    |> cast(attrs, @form_fields ++ @programmatic_fields ++ ~w[is_disabled disabled_reason]a)
    |> Intune.Integration.changeset()
    |> validate_acceptance(:is_verified)
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
      |> DeviceIntegration.changeset()

    changeset
    |> put_change(:id, id)
    |> put_assoc(:device_integration, parent_changeset)
  end

  defp handle_submit({:ok, integration}, socket, queue_sync?) do
    if queue_sync? do
      _ = Oban.insert(Intune.Sync.new(sync_args(integration)))
    end

    {:noreply,
     socket
     |> init()
     |> put_flash(:success, "Device inventory integration saved.")
     |> push_patch(to: index_path(socket))}
  end

  defp handle_submit({:error, :feature_disabled}, socket, _queue_sync?) do
    {:noreply, put_flash(socket, :error, @feature_disabled)}
  end

  defp handle_submit({:error, changeset}, socket, _queue_sync?) do
    {:noreply, assign(socket, form: to_form(changeset))}
  end

  defp init(socket) do
    counts = Database.device_counts(socket.assigns.subject)
    by_state = Enum.reduce(counts, %{}, fn {_id, state, n}, acc -> Map.update(acc, state, n, &(&1 + n)) end)

    by_integration =
      Enum.reduce(counts, %{}, fn {id, _state, n}, acc -> Map.update(acc, id, n, &(&1 + n)) end)

    assign(socket,
      integrations: Database.list_integrations(socket.assigns.subject, by_integration),
      devices_count: by_state |> Map.values() |> Enum.sum(),
      compliant_count: Map.get(by_state, "compliant", 0),
      noncompliant_count: Map.get(by_state, "noncompliant", 0),
      in_grace_period_count: Map.get(by_state, "inGracePeriod", 0)
    )
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

  # A sync error disables and unverifies together, so proving consent again is
  # what makes the integration usable and saving it should say so. An admin who
  # turned it off by hand keeps it off until they turn it back on themselves.
  defp clear_sync_error(changeset) do
    integration = changeset.data

    if get_field(changeset, :is_verified) and integration.is_disabled and
         integration.disabled_reason == "Sync error" do
      Ecto.Changeset.change(changeset, %{
        is_disabled: false,
        disabled_reason: nil,
        error_email_count: 0,
        error_message: nil,
        errored_at: nil
      })
    else
      changeset
    end
  end

  defp toggle_changeset(integration, true) do
    Ecto.Changeset.change(integration, %{
      is_disabled: true,
      disabled_reason: "Disabled by admin"
    })
  end

  # Re-enabling is the only way back from a sync error, so it has to clear the
  # error state too. Leaving errored_at behind would measure the next transient
  # error's 24 hour window from the old failure and disable again at once.
  defp toggle_changeset(integration, false) do
    if integration.is_verified do
      Ecto.Changeset.change(integration, %{
        is_disabled: false,
        disabled_reason: nil,
        error_email_count: 0,
        error_message: nil,
        errored_at: nil
      })
    else
      integration
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.add_error(
        :is_verified,
        "Integration must be verified before enabling"
      )
    end
  end

  defp queue_sync(integration, socket) do
    case Oban.insert(Intune.Sync.new(sync_args(integration))) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :success, "Device inventory sync queued.")}

      {:error, reason} ->
        Logger.info("Failed to queue Intune device inventory sync",
          id: integration.id,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Could not queue device inventory sync.")}
    end
  end

  # The worker resolves the integration by both ids, so the account has to ride
  # along with the row id rather than being trusted from the browser.
  defp sync_args(integration),
    do: %{"account_id" => integration.account_id, "device_integration_id" => integration.id}

  defp account_feature_enabled?(socket),
    do: Portal.Account.device_posture_enabled?(socket.assigns.subject.account)

  defp index_path(socket), do: ~p"/#{socket.assigns.account}/settings/device_posture"

  defmodule Database do
    import Ecto.Query

    alias Portal.{DeviceIntegration, Intune, Safe}

    def list_integrations(subject, device_counts) do
      Intune.Integration
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Enum.map(&Map.put(&1, :devices_count, Map.get(device_counts, &1.id, 0)))
    end

    @doc """
    Counts synced devices by integration and compliance state.

    One grouped aggregate feeds both the per-integration column and the summary
    badges, so neither costs an extra pass over the devices.
    """
    def device_counts(subject) do
      from(d in Intune.Device,
        group_by: [d.device_integration_id, d.compliance_state],
        select: {d.device_integration_id, d.compliance_state, count(d.intune_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def get_integration!(id, subject) do
      from(i in Intune.Integration, where: i.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one!()
    end

    def insert_integration(changeset, subject) do
      with :ok <- ensure_enabled(subject) do
        changeset |> Safe.scoped(subject) |> Safe.insert()
      end
    end

    def update_integration(changeset, subject) do
      with :ok <- ensure_enabled(subject) do
        changeset |> Safe.scoped(subject) |> Safe.update()
      end
    end

    def delete_integration(integration, subject) do
      with :ok <- ensure_enabled(subject) do
        from(i in DeviceIntegration, where: i.id == ^integration.id)
        |> Safe.scoped(subject)
        |> Safe.one!()
        |> Safe.scoped(subject)
        |> Safe.delete()
      end
    end

    # The last line of defence: the page is unreachable and its buttons are gone
    # when the feature is off, but an already-open socket must not be able to
    # write either. The account is re-read rather than taken from the subject,
    # which holds whatever the features were when the socket mounted and would
    # keep answering yes for the life of a session opened before a downgrade.
    defp ensure_enabled(subject) do
      account =
        from(a in Portal.Account, where: a.id == ^subject.account.id)
        |> Safe.unscoped()
        |> Safe.one()

      if account && Portal.Account.device_posture_enabled?(account),
        do: :ok,
        else: {:error, :feature_disabled}
    end
  end
end
