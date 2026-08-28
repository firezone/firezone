defmodule PortalWeb.Settings.DevicePosture do
  use PortalWeb, :live_view

  import Ecto.Changeset

  alias Portal.{Changes.Change, Defender, PostureProvider, Intune, Iru, Santa, SentinelOne, PubSub}
  alias __MODULE__.Database

  require Logger

  @feature_disabled "Device posture is not enabled for your account."

  @types ~w[intune iru defender santa sentinelone]

  @select_type_classes [
    "flex items-center w-full p-4 rounded border transition-colors cursor-pointer",
    "border-border bg-surface",
    "hover:bg-raised hover:border-border-emphasis"
  ]

  @form_fields %{
    "intune" => ~w[name]a,
    "iru" => ~w[name region subdomain api_token]a,
    "defender" => ~w[name]a,
    "santa" => ~w[name api_url api_key]a,
    "sentinelone" => ~w[name management_url api_token]a
  }

  # Set by the verification flow rather than by an input, so they have to be
  # carried across every validate event or a keystroke would drop them.
  @programmatic_fields %{
    "intune" => ~w[tenant_id is_verified]a,
    "iru" => ~w[is_verified]a,
    "defender" => ~w[tenant_id is_verified]a,
    "santa" => ~w[is_verified]a,
    "sentinelone" => ~w[is_verified]a
  }

  # What the Iru test call used, so a change to any of them means the tenant
  # behind the verification is no longer the tenant in the form.
  @iru_verification_fields ~w[region subdomain api_token]a
  @santa_verification_fields ~w[api_url api_key]a
  @sentinelone_verification_fields ~w[management_url api_token]a

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
      :ok = PubSub.Changes.subscribe(socket.assigns.subject.account.id, :posture_providers)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Device Posture",
       trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?(),
       device_posture_enabled?: true,
       type: nil,
       provider: nil,
       form: nil,
       verification_error: nil,
       active_verification: nil,
       pending_verification: nil,
       verifying: false,
       open_provider_actions_id: nil
     )
     |> init()}
  end

  def handle_params(_params, _url, %{assigns: %{live_action: :select_type}} = socket) do
    if account_feature_enabled?(socket) do
      {:noreply, clear_panel(socket)}
    else
      {:noreply, push_patch(socket, to: index_path(socket))}
    end
  end

  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @types do
    if account_feature_enabled?(socket) do
      form =
        type
        |> new_provider()
        |> provider_changeset(type, %{})
        |> to_form(as: :provider)

      {:noreply,
       socket
       |> clear_panel()
       |> assign(type: type, form: form)}
    else
      {:noreply, push_patch(socket, to: index_path(socket))}
    end
  end

  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @types do
    if account_feature_enabled?(socket) do
      provider = Database.get_provider!(type, id, socket.assigns.subject)

      {:noreply,
       socket
       |> clear_panel()
       |> assign(
         type: type,
         provider: provider,
         form: to_form(provider_changeset(provider, type, %{}), as: :provider)
       )}
    else
      {:noreply, push_patch(socket, to: index_path(socket))}
    end
  end

  def handle_params(%{"type" => _type}, _url, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  # Leaving the panel abandons any verification started from it, so the pending
  # verifier goes with it rather than staying live for a callback that no longer
  # has a form to land in.
  def handle_params(_params, _url, socket) do
    {:noreply, clear_panel(socket)}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: index_path(socket))}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, push_patch(socket, to: index_path(socket))}
  end

  def handle_event("handle_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"provider" => attrs}, socket) do
    changeset = socket.assigns.form.source
    type = socket.assigns.type

    attrs = carry_form_changes(attrs, changeset, type)

    attrs =
      Enum.reduce(@programmatic_fields[type], attrs, fn field, attrs ->
        case get_field(changeset, field) do
          nil -> attrs
          value -> Map.put(attrs, Atom.to_string(field), value)
        end
      end)

    changeset =
      changeset.data
      |> provider_changeset(type, attrs)
      |> clear_verification_if_trigger_fields_changed(type)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :provider))}
  end

  def handle_event("start_verification", _params, %{assigns: %{type: "iru"}} = socket) do
    send(self(), :verify_iru)
    {:noreply, assign(socket, verification_error: nil, verifying: true)}
  end

  def handle_event("start_verification", _params, %{assigns: %{type: "santa"}} = socket) do
    send(self(), :verify_santa)
    {:noreply, assign(socket, verification_error: nil, verifying: true)}
  end

  def handle_event(
        "start_verification",
        _params,
        %{assigns: %{type: "sentinelone"}} = socket
      ) do
    send(self(), :verify_sentinelone)
    {:noreply, assign(socket, verification_error: nil, verifying: true)}
  end

  def handle_event("start_verification", _params, socket) do
    verification_type = entra_verification_type(socket.assigns.type)

    with {:ok, %{config: config}} <-
           PortalWeb.OIDC.setup_verification(verification_type, []),
         verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false),
         verification_ref = Ecto.UUID.generate(),
         lv_pid_string = PortalWeb.OIDC.serialize_pid(self()),
         state_token <-
           PortalWeb.OIDC.sign_verification_state(
             lv_pid_string,
             PortalWeb.OIDC.verification_state_type(verification_type),
             %{verification_ref: verification_ref}
           ),
         {:ok, uri} <-
           PortalWeb.OIDC.build_verification_uri(
             verification_type,
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
        Logger.info("Failed to start Microsoft admin consent",
          type: socket.assigns.type,
          reason: inspect(reason)
        )

        {:noreply,
         assign(socket,
           verifying: false,
           verification_error: "Failed to start Microsoft admin consent. Please try again."
         )}
    end
  end

  def handle_event("reset_verification", _params, socket) do
    changeset = socket.assigns.form.source
    type = socket.assigns.type

    base =
      if socket.assigns.live_action == :edit,
        do: changeset.data,
        else: apply_changes(changeset)

    attrs =
      changeset.changes
      |> Map.drop(@programmatic_fields[type])
      |> Map.merge(reset_verification_attrs(type))

    {:noreply,
     assign(socket,
       form: to_form(provider_changeset(base, type, attrs), as: :provider),
       verification_error: nil,
       active_verification: nil,
       verifying: false
     )}
  end

  def handle_event("submit", %{"provider" => attrs}, %{assigns: %{live_action: :new}} = socket) do
    changeset =
      socket
      |> submitted_changeset(attrs)
      |> put_posture_provider_assoc(socket)

    changeset
    |> Database.insert_provider(socket.assigns.subject)
    |> handle_submit(socket, true)
  end

  def handle_event("submit", %{"provider" => attrs}, %{assigns: %{live_action: :edit}} = socket) do
    changeset =
      socket
      |> submitted_changeset(attrs)
      |> clear_sync_error()
      |> put_posture_provider_name()

    # Devices already stored belong to the old tenant, and one coming back from
    # a sync error has been stale for as long as it was disabled, so either way
    # waiting for the next scheduled run would show the wrong inventory.
    resync? =
      Enum.any?(verification_fields(socket.assigns.type), &Map.has_key?(changeset.changes, &1)) or
        get_change(changeset, :is_disabled) == false

    changeset
    |> Database.update_provider(socket.assigns.subject)
    |> handle_submit(socket, resync?)
  end

  def handle_event("toggle_provider_actions", %{"id" => id}, socket) do
    open = if socket.assigns.open_provider_actions_id == id, do: nil, else: id
    {:noreply, assign(socket, open_provider_actions_id: open)}
  end

  def handle_event("close_provider_actions", _params, socket) do
    {:noreply, assign(socket, open_provider_actions_id: nil)}
  end

  def handle_event("sync", %{"id" => id}, socket) do
    socket = assign(socket, open_provider_actions_id: nil)
    provider = Enum.find(socket.assigns.providers, &(&1.id == id))

    cond do
      not account_feature_enabled?(socket) ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      is_nil(provider) ->
        {:noreply, put_flash(socket, :error, "Could not queue device inventory sync.")}

      true ->
        queue_sync(provider, socket)
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    socket = assign(socket, open_provider_actions_id: nil)
    row = Enum.find(socket.assigns.providers, &(&1.id == id))

    if row do
      toggle_provider(row, socket)
    else
      {:noreply, put_flash(socket, :error, "Could not update the provider.")}
    end
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{type: type}} = socket)
      when type in @types do
    provider = Database.get_provider!(type, id, socket.assigns.subject)

    case Database.delete_provider(provider, socket.assigns.subject) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Posture provider deleted.")
         |> push_patch(to: index_path(socket))}

      {:error, :feature_disabled} ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete the provider.")}
    end
  end

  def handle_info(:verify_iru, socket) do
    changeset = socket.assigns.form.source

    client =
      Iru.APIClient.new(
        get_field(changeset, :subdomain),
        get_field(changeset, :region),
        get_field(changeset, :api_token)
      )

    case Iru.APIClient.test_connection(client) do
      :ok ->
        attrs = Map.put(changeset.changes, :is_verified, true)

        {:noreply,
         assign(socket,
           form: to_form(provider_changeset(changeset.data, "iru", attrs), as: :provider),
           verification_error: nil,
           verifying: false
         )}

      {:error, reason} ->
        Logger.info("Failed to verify Iru provider", reason: inspect(reason))

        {:noreply,
         assign(socket, verifying: false, verification_error: iru_verification_error(reason))}
    end
  end

  def handle_info(:verify_santa, socket) do
    changeset = socket.assigns.form.source

    client =
      Santa.APIClient.new(
        get_field(changeset, :api_url),
        get_field(changeset, :api_key)
      )

    case Santa.APIClient.test_connection(client) do
      :ok ->
        attrs = Map.put(changeset.changes, :is_verified, true)

        {:noreply,
         assign(socket,
           form: to_form(provider_changeset(changeset.data, "santa", attrs), as: :provider),
           verification_error: nil,
           verifying: false
         )}

      {:error, reason} ->
        Logger.info("Failed to verify Santa provider", reason: inspect(reason))

        {:noreply,
         assign(socket, verifying: false, verification_error: santa_verification_error(reason))}
    end
  end

  def handle_info(:verify_sentinelone, socket) do
    changeset = socket.assigns.form.source

    client =
      SentinelOne.APIClient.new(
        get_field(changeset, :management_url),
        get_field(changeset, :api_token)
      )

    case SentinelOne.APIClient.test_connection(client) do
      :ok ->
        attrs = Map.put(changeset.changes, :is_verified, true)

        {:noreply,
         assign(socket,
           form: to_form(provider_changeset(changeset.data, "sentinelone", attrs), as: :provider),
           verification_error: nil,
           verifying: false
         )}

      {:error, reason} ->
        Logger.info("Failed to verify SentinelOne provider", reason: inspect(reason))

        {:noreply,
         assign(socket,
           verifying: false,
           verification_error: sentinelone_verification_error(reason)
         )}
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
        {:intune_posture_provider_complete, tenant_id, verification_ref, ack_to},
        socket
      ) do
    complete_tenant_verification(socket, "intune", tenant_id, verification_ref, ack_to)
  end

  def handle_info(
        {:defender_posture_provider_complete, tenant_id, verification_ref, ack_to},
        socket
      ) do
    complete_tenant_verification(socket, "defender", tenant_id, verification_ref, ack_to)
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

  # Any provider row that moves changes what this page shows, including the
  # synced_at a finished run writes, so every change is a re-read.
  def handle_info(%Change{}, socket), do: {:noreply, init(socket)}
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
              <h2 class="text-xs font-semibold text-heading">Posture Providers</h2>
              <span class="text-xs text-subtle tabular-nums">{length(@providers)}</span>
            </div>
            <.link
              patch={~p"/#{@account}/settings/device_posture/new"}
              class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
            >
              <.icon name="ri-add-line" class="w-3 h-3" /> Add posture provider
            </.link>
          </div>

          <div
            :if={not Enum.empty?(@providers)}
            id="device-posture-summary"
            class="flex flex-wrap items-center gap-2 px-6 py-2.5 border-b border-border shrink-0"
          >
            <.dual_badge type="primary">
              <:left>{@devices_count}</:left>
              <:right>Devices synced</:right>
            </.dual_badge>
            <.dual_badge :if={@has_intune?} type="success">
              <:left>{@compliant_count}</:left>
              <:right>Compliant</:right>
            </.dual_badge>
            <.dual_badge :if={@has_intune?} type="danger">
              <:left>{@noncompliant_count}</:left>
              <:right>Not compliant</:right>
            </.dual_badge>
            <.dual_badge :if={@has_intune? and @in_grace_period_count > 0} type="warning">
              <:left>{@in_grace_period_count}</:left>
              <:right>In grace period</:right>
            </.dual_badge>
            <.dual_badge :if={@has_iru?} type="success">
              <:left>{@encrypted_count}</:left>
              <:right>FileVault on</:right>
            </.dual_badge>
            <.dual_badge :if={@has_iru?} type="danger">
              <:left>{@unencrypted_count}</:left>
              <:right>FileVault off</:right>
            </.dual_badge>
            <.dual_badge :if={@has_defender?} type="success">
              <:left>{@sensor_active_count}</:left>
              <:right>Sensor active</:right>
            </.dual_badge>
            <.dual_badge :if={@has_defender? and @sensor_inactive_count > 0} type="danger">
              <:left>{@sensor_inactive_count}</:left>
              <:right>Sensor inactive</:right>
            </.dual_badge>
            <.dual_badge :if={@has_santa?} type="success">
              <:left>{@lockdown_count}</:left>
              <:right>Santa Lockdown</:right>
            </.dual_badge>
            <.dual_badge :if={@has_santa?} type="warning">
              <:left>{@monitor_count}</:left>
              <:right>Santa Monitor</:right>
            </.dual_badge>
            <.dual_badge :if={@has_sentinelone?} type="success">
              <:left>{@sentinelone_active_count}</:left>
              <:right>S1 agent active</:right>
            </.dual_badge>
            <.dual_badge
              :if={@has_sentinelone? and @sentinelone_inactive_count > 0}
              type="danger"
            >
              <:left>{@sentinelone_inactive_count}</:left>
              <:right>S1 agent inactive</:right>
            </.dual_badge>
          </div>

          <div class="flex-1 overflow-auto">
            <%= if Enum.empty?(@providers) do %>
              <div class="flex flex-col items-center justify-center h-full gap-3 text-subtle">
                <p class="text-sm">No posture provider configured.</p>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add posture provider
                </.link>
              </div>
            <% else %>
              <table class="w-full text-sm border-collapse">
                <thead class="sticky top-0 z-10 bg-raised">
                  <tr class="border-b border-border-strong">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                      Provider
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
                  <.provider_row
                    :for={provider <- @providers}
                    account={@account}
                    provider={provider}
                    open_actions_id={@open_provider_actions_id}
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
          (@live_action in [:select_type, :new, :edit] && "translate-x-0") || "translate-x-full"
        ]}
        phx-window-keydown="handle_keydown"
        phx-key="Escape"
      >
        <div :if={@live_action == :select_type} class="flex flex-col h-full overflow-hidden">
          <.panel_header title="Select Provider Type" variant="plain" />
          <div class="flex-1 overflow-y-auto px-5 py-4">
            <p class="mb-4 text-xs text-subtle">
              Select the provider that manages your devices:
            </p>
            <ul class="flex flex-col gap-2">
              <li>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/intune/new"}
                  class={select_type_classes()}
                >
                  <span class="flex items-center gap-3 w-2/5 shrink-0">
                    <.provider_icon provider="intune" size="xl" />
                    <span class="text-sm font-medium text-heading">Microsoft Intune</span>
                  </span>
                  <span class="text-xs text-body">
                    Sync managed devices from a Microsoft Intune tenant.
                  </span>
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/iru/new"}
                  class={select_type_classes()}
                >
                  <span class="flex items-center gap-3 w-2/5 shrink-0">
                    <.provider_icon provider="iru" size="xl" />
                    <span class="text-sm font-medium text-heading">Iru</span>
                  </span>
                  <span class="text-xs text-body">
                    Sync devices and posture from an Iru (formerly Kandji) tenant.
                  </span>
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/defender/new"}
                  class={select_type_classes()}
                >
                  <span class="flex items-center gap-3 w-2/5 shrink-0">
                    <.provider_icon provider="defender" size="xl" />
                    <span class="text-sm font-medium text-heading">
                      Microsoft Defender for Endpoint
                    </span>
                  </span>
                  <span class="text-xs text-body">
                    Sync onboarded machines from a Microsoft Defender for Endpoint tenant.
                  </span>
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/santa/new"}
                  class={select_type_classes()}
                >
                  <span class="flex items-center gap-3 w-2/5 shrink-0">
                    <.provider_icon provider="santa" size="xl" />
                    <span class="text-sm font-medium text-heading">Santa</span>
                  </span>
                  <span class="text-xs text-body">
                    Sync Santa hosts from North Pole Security Workshop.
                  </span>
                </.link>
              </li>
              <li>
                <.link
                  patch={~p"/#{@account}/settings/device_posture/sentinelone/new"}
                  class={select_type_classes()}
                >
                  <span class="flex items-center gap-3 w-2/5 shrink-0">
                    <.provider_icon provider="sentinelone" size="xl" />
                    <span class="text-sm font-medium text-heading">SentinelOne</span>
                  </span>
                  <span class="text-xs text-body">
                    Sync endpoint agents and posture from a SentinelOne tenant.
                  </span>
                </.link>
              </li>
            </ul>
          </div>
        </div>

        <div :if={@live_action in [:new, :edit] and @form} class="flex flex-col h-full overflow-hidden">
          <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
            <div class="flex items-center gap-2">
              <.link
                :if={@live_action == :new}
                patch={~p"/#{@account}/settings/device_posture/new"}
                class="flex items-center justify-center w-6 h-6 rounded text-subtle hover:text-heading hover:bg-raised transition-colors"
                title="Back"
              >
                <.icon name="ri-arrow-left-line" class="w-4 h-4" />
              </.link>
              <.provider_icon provider={@type} size="sm" />
              <h2 class="text-sm font-semibold text-heading">
                {if @live_action == :new,
                  do: "Add #{provider_title(@type)}",
                  else: "Edit #{provider_title(@type)}"}
              </h2>
            </div>
            <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
          </div>

          <div class="flex-1 overflow-y-auto px-5 py-4">
            <.provider_form
              form={@form}
              type={@type}
              editing?={@live_action == :edit}
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
              phx-value-id={@provider.id}
              data-confirm="Delete this provider and all devices synced from it?"
            >
              Delete
            </.button>
            <div class="ml-auto flex items-center gap-2">
              <.button type="button" phx-click="close_panel">Cancel</.button>
              <.button
                form="device-posture-form"
                type="submit"
                style="primary"
                disabled={not @form.source.valid?}
              >
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
          <h2 class="text-xs font-semibold text-heading">Posture Providers</h2>
        </div>
      </div>

      <div class="flex-1 overflow-hidden relative">
        <div class="blur-xs pointer-events-none select-none opacity-60">
          <table class="w-full text-sm border-collapse">
            <thead class="bg-raised">
              <tr class="border-b border-border-strong">
                <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                  Provider
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
                    <.provider_icon provider="intune" size="lg" />
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
              <tr class="border-b border-border">
                <td class="px-6 py-3">
                  <div class="flex items-center gap-3">
                    <.provider_icon provider="iru" size="lg" />
                    <div class="min-w-0">
                      <span class="text-sm font-medium text-heading truncate block">
                        Iru
                      </span>
                      <span class="text-xs text-subtle">Iru (formerly Kandji)</span>
                    </div>
                  </div>
                </td>
                <td class="px-6 py-3 w-28">
                  <.status_badge style={:success}>Active</.status_badge>
                </td>
                <td class="px-6 py-3 w-48">
                  <span class="text-sm text-body font-mono truncate block">acme</span>
                </td>
                <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">312</td>
                <td class="px-6 py-3 w-40"><span class="text-xs text-body">1 hour ago</span></td>
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

  attr :provider, :map, required: true
  attr :account, :map, required: true
  attr :open_actions_id, :string, default: nil

  defp provider_row(assigns) do
    ~H"""
    <tr class="border-b border-border hover:bg-raised">
      <td class="px-6 py-3">
        <div class="flex items-center gap-3">
          <.provider_icon provider={@provider.type} size="lg" />
          <div class="min-w-0">
            <span class="text-sm font-medium text-heading truncate block" title={@provider.name}>
              {@provider.name}
            </span>
            <span class="text-xs text-subtle">{provider_title(@provider.type)}</span>
          </div>
        </div>
      </td>
      <td class="px-6 py-3 w-28">
        <.provider_status provider={@provider} />
      </td>
      <td class="px-6 py-3 w-48">
        <span class="text-sm text-body font-mono truncate block">
          {@provider.identifier || "—"}
        </span>
      </td>
      <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">
        {@provider.devices_count}
      </td>
      <td class="px-6 py-3 w-40">
        <span :if={@provider.synced_at} class="text-xs text-body">
          <.relative_datetime datetime={@provider.synced_at} />
        </span>
        <span :if={is_nil(@provider.synced_at)} class="text-xs text-subtle">Never</span>
      </td>
      <td class="px-6 py-3 w-14">
        <div class="flex justify-end">
          <.actions_dropdown
            open={@open_actions_id == @provider.id}
            close_event="close_provider_actions"
            phx-click="toggle_provider_actions"
            phx-value-id={@provider.id}
          >
            <.link
              patch={
                ~p"/#{@account}/settings/device_posture/#{@provider.type}/#{@provider.id}/edit"
              }
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
            >
              <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
            </.link>
            <button
              type="button"
              phx-click="sync"
              phx-value-id={@provider.id}
              disabled={@provider.is_disabled}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <.icon name="ri-loop-left-line" class="w-3.5 h-3.5 shrink-0" /> Sync Now
            </button>
            <div class="my-1 border-t border-border"></div>
            <button
              type="button"
              phx-click="toggle"
              phx-value-id={@provider.id}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
            >
              <.icon
                name={if @provider.is_disabled, do: "ri-play-line", else: "ri-pause-line"}
                class="w-3.5 h-3.5 shrink-0"
              />
              {if @provider.is_disabled, do: "Enable", else: "Disable"}
            </button>
          </.actions_dropdown>
        </div>
      </td>
    </tr>
    """
  end

  attr :provider, :map, required: true

  defp provider_status(assigns) do
    {style, label} =
      cond do
        assigns.provider.is_disabled and assigns.provider.disabled_reason == "Sync error" ->
          {:danger, "Error"}

        assigns.provider.is_disabled ->
          {:neutral, "Disabled"}

        assigns.provider.errored_at ->
          {:warning, "Warning"}

        assigns.provider.is_verified ->
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
  attr :type, :string, required: true
  attr :editing?, :boolean, default: false
  attr :verification_error, :string, default: nil
  attr :verifying, :boolean, default: false

  defp provider_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="device-posture-form"
      as={:provider}
      phx-change="validate"
      phx-submit="submit"
      class="space-y-5"
    >
      <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />

      <div :if={@type == "iru"}>
        <.input
          field={@form[:region]}
          type="select"
          label="Region"
          options={iru_region_options()}
          required
        />
        <p class="mt-1 text-xs text-subtle">
          The region your Iru tenant is hosted in.
        </p>
      </div>

      <div :if={@type == "santa"}>
        <.input
          field={@form[:api_url]}
          type="url"
          label="Workshop URL"
          autocomplete="off"
          phx-debounce="300"
          placeholder="https://acme.workshop.cloud"
          required
        />
        <p class="mt-1 text-xs text-subtle">
          The base URL of the Workshop tenant that manages your Santa hosts.
        </p>
      </div>

      <div :if={@type == "santa"}>
        <label for={@form[:api_key].id} class="block text-xs font-medium text-body mb-1.5">
          API Key <span class="text-error">*</span>
        </label>
        <.input
          field={@form[:api_key]}
          value={typed_api_key(@form)}
          type="password"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          placeholder={if @editing?, do: "Leave blank to keep the current key"}
          required={not @editing?}
        />
        <p class="mt-1 text-xs text-subtle">
          Create a read-only key in Workshop under API Keys. It must be able to call
          <code class="text-xs">{Santa.APIClient.list_hosts_path()}</code>.
        </p>
      </div>

      <div :if={@type == "sentinelone"}>
        <.input
          field={@form[:management_url]}
          type="text"
          label="Management URL"
          autocomplete="off"
          phx-debounce="300"
          placeholder="https://acme.sentinelone.net"
          required
        />
        <p class="mt-1 text-xs text-subtle">
          The origin shown in your SentinelOne Management Console URL. A pasted dashboard or
          API URL is reduced to this origin.
        </p>
      </div>

      <div :if={@type == "sentinelone"}>
        <label for={@form[:api_token].id} class="block text-xs font-medium text-body mb-1.5">
          API Token <span class="text-error">*</span>
        </label>
        <.input
          field={@form[:api_token]}
          value={typed_api_token(@form)}
          type="password"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          placeholder={if @editing?, do: "Leave blank to keep the current token"}
          required={not @editing?}
        />
        <p class="mt-1 text-xs text-subtle">
          Generate a token for a dedicated SentinelOne service user that can view endpoints.
        </p>
        <div class="mt-2 rounded border border-border bg-raised px-3 py-2">
          <p class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
            Required
          </p>
          <p class="mt-1 text-xs font-mono text-body">
            GET {SentinelOne.APIClient.agents_path()}
          </p>
        </div>
      </div>

      <div :if={@type == "iru"}>
        <.input
          field={@form[:subdomain]}
          type="text"
          label="Subdomain"
          autocomplete="off"
          phx-debounce="300"
          required
        />
        <p class="mt-1 text-xs text-subtle">
          The first label of the API URL under Settings > Access in Iru. For
          <code class="text-xs">https://acme.api.kandji.io</code>
          the subdomain is <code class="text-xs">acme</code>.
        </p>
      </div>

      <div :if={@type == "iru"}>
        <label for={@form[:api_token].id} class="block text-xs font-medium text-body mb-1.5">
          API Token <span class="text-error">*</span>
        </label>
        <.input
          field={@form[:api_token]}
          value={typed_api_token(@form)}
          type="password"
          autocomplete="off"
          phx-debounce="300"
          data-1p-ignore
          placeholder={if @editing?, do: "Leave blank to keep the current token"}
          required={not @editing?}
        />
        <p class="mt-1 text-xs text-subtle">
          Create the token in Iru under Settings > Access, then turn these endpoints on for it.
        </p>

        <div class="mt-2 rounded border border-border bg-raised px-3 py-2 space-y-2.5">
          <div>
            <p class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
              Required
            </p>
            <p class="mt-1 text-xs font-mono text-body">GET {Iru.APIClient.devices_path()}</p>
          </div>
          <div>
            <p class="text-[10px] font-semibold tracking-widest uppercase text-subtle">
              Posture data
            </p>
            <ul class="mt-1 space-y-0.5">
              <li
                :for={category <- Iru.Sync.prism_categories()}
                class="text-xs font-mono text-body"
              >
                GET {Iru.APIClient.prism_path(category)}
              </li>
            </ul>
            <p class="mt-1.5 text-xs text-subtle">
              An endpoint you leave off is skipped, and the fields it reports stay empty.
            </p>
          </div>
        </div>
      </div>

      <div id="provider-verification" class="p-4 border border-border bg-raised rounded">
        <.flash :if={@verification_error} kind={:error}>
          {@verification_error}
        </.flash>
        <div class="flex items-center justify-between">
          <div class="flex-1">
            <h3 class="text-sm font-semibold text-heading">Provider Verification</h3>
            <p class="mt-1 text-xs text-body">
              {verification_help_text(@form, @type)}
            </p>
          </div>
          <div class="ml-4">
            <.verification_status form={@form} type={@type} verifying={@verifying} />
          </div>
        </div>

        <div
          :if={@type in ~w[intune defender]}
          class="mt-4 pt-4 border-t border-border space-y-3"
        >
          <div class="flex justify-between items-center">
            <label class="text-xs font-medium text-body">Tenant ID</label>
            <div class="text-right">
              <p id="provider-tenant-id" class="text-xs font-semibold text-heading">
                {verification_tenant_id(@form)}
              </p>
            </div>
          </div>
          <.reset_verification_button form={@form} />
        </div>
      </div>
    </.form>
    """
  end

  attr :form, :map, required: true
  attr :type, :string, required: true
  attr :verifying, :boolean, required: true

  defp verification_status(assigns) do
    assigns = assign(assigns, :verified?, get_field(assigns.form.source, :is_verified) == true)

    ~H"""
    <div id="provider-verification-open-url" phx-hook="OpenURL">
      <div
        :if={@verified?}
        id="provider-verification-status"
        class="flex items-center text-green-700 bg-green-100 px-4 py-2 rounded-sm"
      >
        <.icon name="ri-checkbox-circle-line" class="h-5 w-5 mr-2" />
        <span class="font-medium">Verified</span>
      </div>
      <.button
        :if={not @verified? and not @verifying}
        id="provider-verification-button"
        type="button"
        style="primary"
        icon={
          if @type in ~w[intune defender], do: "ri-external-link-line", else: "ri-plug-line"
        }
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

  attr :form, :map, required: true

  defp reset_verification_button(assigns) do
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

  defp verification_help_text(form, type) do
    cond do
      get_field(form.source, :is_verified) ->
        "This provider has been successfully verified."

      type == "intune" ->
        "Grant Microsoft admin consent to verify the Intune provider."

      type == "defender" ->
        "Grant Microsoft admin consent to verify the Defender for Endpoint provider."

      type == "iru" ->
        "Check that the API token can read devices in the Iru tenant."

      type == "sentinelone" ->
        "Check that the API token can view endpoints in the SentinelOne tenant."

      true ->
        "Check that the API key can read hosts in the Workshop tenant."
    end
  end

  defp verification_tenant_id(form) do
    if get_field(form.source, :is_verified) do
      get_field(form.source, :tenant_id)
    else
      "Awaiting verification..."
    end
  end

  # The stored token never goes back to the browser, so the box starts empty on
  # an edit. Leaving it that way submits an empty string, which cast/3 reads as
  # no change and the stored token stays.
  defp typed_api_token(form), do: get_change(form.source, :api_token) || ""
  defp typed_api_key(form), do: get_change(form.source, :api_key) || ""

  defp provider_title("intune"), do: "Microsoft Intune"
  defp provider_title("iru"), do: "Iru (formerly Kandji)"
  defp provider_title("defender"), do: "Microsoft Defender for Endpoint"
  defp provider_title("santa"), do: "Santa (Workshop)"
  defp provider_title("sentinelone"), do: "SentinelOne"

  defp new_provider("intune"), do: %Intune.PostureProvider{}
  defp new_provider("iru"), do: %Iru.PostureProvider{}
  defp new_provider("defender"), do: %Defender.PostureProvider{}
  defp new_provider("santa"), do: %Santa.PostureProvider{}
  defp new_provider("sentinelone"), do: %SentinelOne.PostureProvider{}

  defp iru_region_options, do: [{"United States", "us"}, {"European Union", "eu"}]

  defp select_type_classes, do: @select_type_classes

  defp reset_verification_attrs("intune"), do: %{tenant_id: nil, is_verified: false}
  defp reset_verification_attrs("iru"), do: %{is_verified: false}
  defp reset_verification_attrs("defender"), do: %{tenant_id: nil, is_verified: false}
  defp reset_verification_attrs("santa"), do: %{is_verified: false}
  defp reset_verification_attrs("sentinelone"), do: %{is_verified: false}

  # Admin consent, or a successful call against the tenant, is what proves the
  # provider works, so the form refuses to save until one succeeded. The sync
  # still needs to clear the flag when access is later revoked, so this stays
  # out of the base changeset.
  defp provider_changeset(provider, type, attrs) do
    provider
    |> cast(
      drop_blank_secret(attrs),
      @form_fields[type] ++ @programmatic_fields[type] ++ ~w[is_disabled disabled_reason]a
    )
    |> base_changeset(type)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_acceptance(:is_verified)
  end

  # An untouched token box submits an empty string, and cast/3 reads that as
  # "put the field back to its default", which would blank a working token.
  # Dropping it means the stored one stays; a new provider still has none and
  # still fails the required check.
  defp drop_blank_secret(attrs) do
    Enum.reduce(["api_token", "api_key"], attrs, fn field, attrs ->
      if blank_secret?(attrs[field]), do: Map.delete(attrs, field), else: attrs
    end)
  end

  defp blank_secret?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_secret?(_value), do: false

  # Debounced inputs are not always included when a different input triggers
  # validation. Keep values already received from the browser until that input
  # sends a newer value of its own.
  defp carry_form_changes(attrs, changeset, type) do
    changeset.changes
    |> Map.take(@form_fields[type])
    |> Map.new(fn {field, value} -> {Atom.to_string(field), value} end)
    |> Map.merge(attrs)
  end

  defp base_changeset(changeset, "intune"), do: Intune.PostureProvider.changeset(changeset)
  defp base_changeset(changeset, "iru"), do: Iru.PostureProvider.changeset(changeset)
  defp base_changeset(changeset, "defender"), do: Defender.PostureProvider.changeset(changeset)
  defp base_changeset(changeset, "santa"), do: Santa.PostureProvider.changeset(changeset)
  defp base_changeset(changeset, "sentinelone"),
    do: SentinelOne.PostureProvider.changeset(changeset)

  defp clear_verification_if_trigger_fields_changed(changeset, "iru") do
    if Enum.any?(@iru_verification_fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp clear_verification_if_trigger_fields_changed(changeset, "santa") do
    if Enum.any?(@santa_verification_fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp clear_verification_if_trigger_fields_changed(changeset, "sentinelone") do
    if Enum.any?(@sentinelone_verification_fields, &get_change(changeset, &1)) do
      put_change(changeset, :is_verified, false)
    else
      changeset
    end
  end

  defp clear_verification_if_trigger_fields_changed(changeset, _type), do: changeset

  defp submitted_changeset(socket, attrs) do
    source = socket.assigns.form.source
    type = socket.assigns.type

    attrs =
      Enum.reduce(@programmatic_fields[type], attrs, fn field, attrs ->
        Map.put(attrs, Atom.to_string(field), get_field(source, field))
      end)

    source.data
    |> provider_changeset(type, attrs)
    |> clear_verification_if_submitted_fields_changed(source, type)
  end

  # A submit cancels pending debounced change events, but its FormData contains
  # the browser's current values. Compare that submitted candidate with the
  # form state that was actually verified so a changed tenant or credential
  # cannot inherit stale verification.
  defp clear_verification_if_submitted_fields_changed(changeset, source, type) do
    if Enum.any?(verification_fields(type), fn field ->
         get_field(changeset, field) != get_field(source, field)
       end) do
      changeset
      |> put_change(:is_verified, false)
      |> add_error(:is_verified, "must be accepted", validation: :acceptance)
    else
      changeset
    end
  end

  defp put_posture_provider_assoc(changeset, socket) do
    id = Ecto.UUID.generate()

    parent_changeset =
      %PostureProvider{}
      |> Ecto.Changeset.change(%{
        id: id,
        account_id: socket.assigns.subject.account.id,
        type: provider_type_atom(socket.assigns.type),
        name: get_field(changeset, :name)
      })
      |> PostureProvider.changeset()

    changeset
    |> put_change(:id, id)
    |> put_assoc(:posture_provider, parent_changeset)
  end

  # The name is stored on the shared row, so an edit writes it through the
  # association rather than through the provider's own columns.
  defp put_posture_provider_name(changeset) do
    parent_changeset =
      changeset.data.posture_provider
      |> Ecto.Changeset.change(%{name: get_field(changeset, :name)})
      |> PostureProvider.changeset()

    put_assoc(changeset, :posture_provider, parent_changeset)
  end

  defp handle_submit({:ok, provider}, socket, queue_sync?) do
    if queue_sync? do
      _ = Oban.insert(sync_worker(socket.assigns.type).new(sync_args(provider)))
    end

    {:noreply,
     socket
     |> init()
     |> put_flash(:success, "Posture provider saved.")
     |> push_patch(to: index_path(socket))}
  end

  defp handle_submit({:error, :feature_disabled}, socket, _queue_sync?) do
    {:noreply, put_flash(socket, :error, @feature_disabled)}
  end

  # A uniqueness error lands on a field with no input of its own, such as the
  # Intune tenant id the consent flow filled in, so it would otherwise be
  # rendered nowhere.
  defp handle_submit({:error, changeset}, socket, _queue_sync?) do
    changeset = hoist_posture_provider_errors(changeset)

    socket =
      case hidden_error(changeset, socket.assigns.type) do
        nil -> socket
        message -> put_flash(socket, :error, message)
      end

    {:noreply, assign(socket, form: to_form(changeset, as: :provider))}
  end

  # The name is written through the association, so a duplicate one comes back
  # on the shared row's changeset, which the form does not render.
  defp hoist_posture_provider_errors(changeset) do
    case changeset.changes[:posture_provider] do
      %Ecto.Changeset{errors: errors} ->
        Enum.reduce(errors, changeset, fn {field, {message, opts}}, acc ->
          add_error(acc, field, message, opts)
        end)

      _no_association ->
        changeset
    end
  end

  defp hidden_error(changeset, type) do
    Enum.find_value(changeset.errors, fn {field, {message, _opts}} ->
      if field not in @form_fields[type], do: message
    end)
  end

  defp init(socket) do
    subject = socket.assigns.subject
    intune_counts = Database.intune_device_counts(subject)
    iru_counts = Database.iru_device_counts(subject)
    defender_counts = Database.defender_device_counts(subject)
    santa_counts = Database.santa_device_counts(subject)
    sentinelone_counts = Database.sentinelone_device_counts(subject)

    by_provider =
      Enum.reduce(
        intune_counts ++ iru_counts ++ defender_counts ++ santa_counts ++ sentinelone_counts,
        %{},
        fn {id, _key, n}, acc -> Map.update(acc, id, n, &(&1 + n)) end
      )

    by_compliance = group_counts(intune_counts)
    by_filevault = group_counts(iru_counts)
    by_health = group_counts(defender_counts)
    by_santa_mode = group_counts(santa_counts)
    by_sentinelone_activity = group_counts(sentinelone_counts)
    providers = Database.list_providers(subject, by_provider)

    assign(socket,
      providers: providers,
      has_intune?: Enum.any?(providers, &(&1.type == "intune")),
      has_iru?: Enum.any?(providers, &(&1.type == "iru")),
      has_defender?: Enum.any?(providers, &(&1.type == "defender")),
      has_santa?: Enum.any?(providers, &(&1.type == "santa")),
      has_sentinelone?: Enum.any?(providers, &(&1.type == "sentinelone")),
      devices_count: by_provider |> Map.values() |> Enum.sum(),
      compliant_count: Map.get(by_compliance, "compliant", 0),
      noncompliant_count: Map.get(by_compliance, "noncompliant", 0),
      in_grace_period_count: Map.get(by_compliance, "inGracePeriod", 0),
      encrypted_count: Map.get(by_filevault, true, 0),
      unencrypted_count: Map.get(by_filevault, false, 0),
      sensor_active_count: Map.get(by_health, "Active", 0),
      # Defender has five ways of saying a sensor stopped reporting, so the
      # badge counts everything that is not "Active" rather than one of them.
      sensor_inactive_count: by_health |> Map.drop(["Active", nil]) |> Map.values() |> Enum.sum(),
      lockdown_count: Map.get(by_santa_mode, "LOCKDOWN", 0),
      monitor_count: Map.get(by_santa_mode, "MONITOR", 0),
      sentinelone_active_count: Map.get(by_sentinelone_activity, true, 0),
      sentinelone_inactive_count: Map.get(by_sentinelone_activity, false, 0)
    )
  end

  defp group_counts(counts) do
    Enum.reduce(counts, %{}, fn {_id, key, n}, acc -> Map.update(acc, key, n, &(&1 + n)) end)
  end

  defp clear_panel(socket) do
    assign(socket,
      type: nil,
      provider: nil,
      form: nil,
      verification_error: nil,
      active_verification: nil,
      pending_verification: nil,
      verifying: false
    )
  end

  defp active_verification?(socket, verification_ref) do
    match?(
      %{verification_ref: ^verification_ref} when is_binary(verification_ref),
      socket.assigns.active_verification
    )
  end

  # Admin consent proves the tenant rather than the form, so the tenant id the
  # callback carries is what lands in the changeset.
  defp complete_tenant_verification(socket, type, tenant_id, verification_ref, ack_to) do
    if active_verification?(socket, verification_ref) and socket.assigns.form do
      changeset = socket.assigns.form.source

      attrs =
        changeset.changes
        |> Map.put(:tenant_id, tenant_id)
        |> Map.put(:is_verified, true)

      maybe_send_verification_ack(ack_to)

      {:noreply,
       assign(socket,
         form: to_form(provider_changeset(changeset.data, type, attrs), as: :provider),
         active_verification: nil,
         verification_error: nil,
         verifying: false
       )}
    else
      maybe_send_verification_ack(ack_to)
      {:noreply, socket}
    end
  end

  defp maybe_send_verification_ack({pid, ref}) when is_pid(pid) do
    send(pid, {:verification_ack, ref})
  end

  defp maybe_send_verification_ack(_), do: :ok

  # A sync error disables and unverifies together, so proving access again is
  # what makes the provider usable and saving it should say so. An admin who
  # turned it off by hand keeps it off until they turn it back on themselves.
  defp clear_sync_error(changeset) do
    provider = changeset.data

    if get_field(changeset, :is_verified) and provider.is_disabled and
         provider.disabled_reason == "Sync error" do
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

  defp toggle_provider(row, socket) do
    provider = Database.get_provider!(row.type, row.id, socket.assigns.subject)
    changeset = toggle_changeset(provider, not provider.is_disabled)

    case Database.update_provider(changeset, socket.assigns.subject) do
      {:ok, _provider} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(
           :success,
           "Posture provider #{if(provider.is_disabled, do: "enabled", else: "disabled")}."
         )}

      {:error, :feature_disabled} ->
        {:noreply, put_flash(socket, :error, @feature_disabled)}

      {:error, %Ecto.Changeset{errors: [{:is_verified, {message, _}} | _]}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update the provider.")}
    end
  end

  defp toggle_changeset(provider, true) do
    Ecto.Changeset.change(provider, %{
      is_disabled: true,
      disabled_reason: "Disabled by admin"
    })
  end

  # Re-enabling is the only way back from a sync error, so it has to clear the
  # error state too. Leaving errored_at behind would measure the next transient
  # error's 24 hour window from the old failure and disable again at once.
  defp toggle_changeset(provider, false) do
    if provider.is_verified do
      Ecto.Changeset.change(provider, %{
        is_disabled: false,
        disabled_reason: nil,
        error_email_count: 0,
        error_message: nil,
        errored_at: nil
      })
    else
      provider
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.add_error(
        :is_verified,
        "Provider must be verified before enabling"
      )
    end
  end

  defp queue_sync(provider, socket) do
    case Oban.insert(sync_worker(provider.type).new(sync_args(provider))) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :success, "Device inventory sync queued.")}

      {:error, reason} ->
        Logger.info("Failed to queue device inventory sync",
          id: provider.id,
          type: provider.type,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Could not queue device inventory sync.")}
    end
  end

  defp sync_worker("intune"), do: Intune.Sync
  defp sync_worker("iru"), do: Iru.Sync
  defp sync_worker("defender"), do: Defender.Sync
  defp sync_worker("santa"), do: Santa.Sync
  defp sync_worker("sentinelone"), do: SentinelOne.Sync

  defp provider_type_atom("intune"), do: :intune
  defp provider_type_atom("iru"), do: :iru
  defp provider_type_atom("defender"), do: :defender
  defp provider_type_atom("santa"), do: :santa
  defp provider_type_atom("sentinelone"), do: :sentinelone

  defp entra_verification_type("intune"), do: "intune_posture_provider"
  defp entra_verification_type("defender"), do: "defender_posture_provider"

  defp verification_fields("intune"), do: [:tenant_id]
  defp verification_fields("iru"), do: @iru_verification_fields
  defp verification_fields("defender"), do: [:tenant_id]
  defp verification_fields("santa"), do: @santa_verification_fields
  defp verification_fields("sentinelone"), do: @sentinelone_verification_fields

  # The worker resolves the provider by both ids, so the account has to ride
  # along with the row id rather than being trusted from the browser.
  defp sync_args(provider),
    do: %{"account_id" => provider.account_id, "posture_provider_id" => provider.id}

  defp iru_verification_error(%Req.Response{status: 401}),
    do: "Iru rejected the API token. Check that it is correct and still enabled."

  defp iru_verification_error(%Req.Response{status: 403}),
    do: "The API token cannot list devices. Give it the Devices permission in Iru."

  defp iru_verification_error(%Req.Response{status: 404}),
    do: "No Iru tenant answered. Check the subdomain and the region."

  defp iru_verification_error(%Req.Response{status: status}),
    do: "Iru returned HTTP #{status}. Please try again."

  defp iru_verification_error(_reason),
    do: "Could not reach the Iru tenant. Check the subdomain and the region."

  defp santa_verification_error(%Req.Response{status: 401}),
    do: "Workshop rejected the API key. Check that it is correct and has not expired."

  defp santa_verification_error(%Req.Response{status: 403}),
    do: "The API key cannot list hosts. Use a read-only or superadmin Workshop key."

  defp santa_verification_error(%Req.Response{status: 404}),
    do: "No Workshop API answered at that URL. Check the tenant URL."

  defp santa_verification_error(%Req.Response{status: status}),
    do: "Workshop returned HTTP #{status}. Please try again."

  defp santa_verification_error(_reason),
    do: "Could not reach the Workshop tenant. Check its URL."

  defp sentinelone_verification_error(%Req.Response{status: 401}),
    do: "SentinelOne rejected the API token. Check that it is correct and still enabled."

  defp sentinelone_verification_error(%Req.Response{status: 403}),
    do: "The API token cannot view endpoints. Grant its service user endpoint view access."

  defp sentinelone_verification_error(%Req.Response{status: 404}),
    do: "No SentinelOne Management Console answered. Check the Management URL."

  defp sentinelone_verification_error(%Req.Response{status: status}),
    do: "SentinelOne returned HTTP #{status}. Please try again."

  defp sentinelone_verification_error({:invalid_response, _message, _body}),
    do: "SentinelOne returned an unexpected endpoint response."

  defp sentinelone_verification_error(_reason),
    do: "Could not reach the SentinelOne tenant. Check the Management URL."

  defp account_feature_enabled?(socket),
    do: Portal.Account.device_posture_enabled?(socket.assigns.subject.account)

  defp index_path(socket), do: ~p"/#{socket.assigns.account}/settings/device_posture"

  defmodule Database do
    import Ecto.Query

    alias Portal.{Defender, PostureProvider, Intune, Iru, Santa, Safe, SentinelOne}

    def list_providers(subject, device_counts) do
      intune =
        Intune.PostureProvider
        |> with_name()
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.map(fn {provider, name} ->
          row(provider, "intune", name, provider.tenant_id, device_counts)
        end)

      iru =
        Iru.PostureProvider
        |> with_name()
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.map(fn {provider, name} ->
          row(provider, "iru", name, provider.subdomain, device_counts)
        end)

      defender =
        Defender.PostureProvider
        |> with_name()
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.map(fn {provider, name} ->
          row(provider, "defender", name, provider.tenant_id, device_counts)
        end)

      santa =
        Santa.PostureProvider
        |> with_name()
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.map(fn {provider, name} ->
          row(provider, "santa", name, provider.api_url, device_counts)
        end)

      sentinelone =
        SentinelOne.PostureProvider
        |> with_name()
        |> Safe.scoped(subject)
        |> Safe.all()
        |> Enum.map(fn {provider, name} ->
          row(provider, "sentinelone", name, provider.management_url, device_counts)
        end)

      Enum.sort_by(intune ++ iru ++ defender ++ santa ++ sentinelone, &{
        String.downcase(&1.name),
        &1.type
      })
    end

    defp with_name(schema) do
      from(p in schema,
        join: s in PostureProvider,
        on: s.account_id == p.account_id and s.id == p.id,
        select: {p, s.name}
      )
    end

    @doc """
    Counts synced Intune devices by provider and compliance state.

    One grouped aggregate feeds both the per-provider column and the summary
    badges, so neither costs an extra pass over the devices.
    """
    def intune_device_counts(subject) do
      from(d in Intune.Device,
        group_by: [d.posture_provider_id, d.compliance_state],
        select: {d.posture_provider_id, d.compliance_state, count(d.intune_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @doc """
    Counts synced Iru devices by provider and FileVault state.
    """
    def iru_device_counts(subject) do
      from(d in Iru.Device,
        group_by: [d.posture_provider_id, d.filevault_enabled],
        select: {d.posture_provider_id, d.filevault_enabled, count(d.iru_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @doc """
    Counts synced Defender devices by provider and sensor health.
    """
    def defender_device_counts(subject) do
      from(d in Defender.Device,
        group_by: [d.posture_provider_id, d.health_status],
        select: {d.posture_provider_id, d.health_status, count(d.defender_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @doc "Counts synced Santa hosts by provider and client mode."
    def santa_device_counts(subject) do
      from(d in Santa.Device,
        group_by: [d.posture_provider_id, d.last_seen_client_mode],
        select: {d.posture_provider_id, d.last_seen_client_mode, count(d.santa_id)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @doc "Counts synced SentinelOne devices by provider and agent activity."
    def sentinelone_device_counts(subject) do
      from(d in SentinelOne.Device,
        group_by: [d.posture_provider_id, d.is_active],
        select: {d.posture_provider_id, d.is_active, count(d.uuid)}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def get_provider!(type, id, subject) do
      provider =
        from(p in schema(type), where: p.id == ^id, preload: [:posture_provider])
        |> Safe.scoped(subject)
        |> Safe.one!()

      %{provider | name: provider.posture_provider.name}
    end

    def insert_provider(changeset, subject) do
      with :ok <- ensure_enabled(subject) do
        changeset |> Safe.scoped(subject) |> Safe.insert()
      end
    end

    def update_provider(changeset, subject) do
      with :ok <- ensure_enabled(subject) do
        changeset |> Safe.scoped(subject) |> Safe.update()
      end
    end

    def delete_provider(provider, subject) do
      with :ok <- ensure_enabled(subject) do
        from(p in PostureProvider, where: p.id == ^provider.id)
        |> Safe.scoped(subject)
        |> Safe.one!()
        |> Safe.scoped(subject)
        |> Safe.delete()
      end
    end

    defp schema("intune"), do: Intune.PostureProvider
    defp schema("iru"), do: Iru.PostureProvider
    defp schema("defender"), do: Defender.PostureProvider
    defp schema("santa"), do: Santa.PostureProvider
    defp schema("sentinelone"), do: SentinelOne.PostureProvider

    defp row(provider, type, name, identifier, device_counts) do
      %{
        id: provider.id,
        account_id: provider.account_id,
        type: type,
        name: name,
        identifier: identifier,
        is_verified: provider.is_verified,
        is_disabled: provider.is_disabled,
        disabled_reason: provider.disabled_reason,
        errored_at: provider.errored_at,
        synced_at: provider.synced_at,
        devices_count: Map.get(device_counts, provider.id, 0)
      }
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
