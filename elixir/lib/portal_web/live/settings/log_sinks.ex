defmodule PortalWeb.Settings.LogSinks do
  use PortalWeb, :live_view

  alias Portal.Datadog
  alias Portal.Elastic
  alias Portal.NewRelic
  alias Portal.Sentinel
  alias Portal.S3
  alias Portal.Splunk
  alias __MODULE__.Database

  import Ecto.Changeset

  require Logger

  @modules %{
    "splunk" => Splunk.LogSink,
    "datadog" => Datadog.LogSink,
    "newrelic" => NewRelic.LogSink,
    "elastic" => Elastic.LogSink,
    "sentinel" => Sentinel.LogSink,
    "s3" => S3.LogSink
  }

  @types Map.keys(@modules)

  @datadog_site_options [
    {"US1 (datadoghq.com)", "datadoghq.com"},
    {"US3 (us3.datadoghq.com)", "us3.datadoghq.com"},
    {"US5 (us5.datadoghq.com)", "us5.datadoghq.com"},
    {"EU1 (datadoghq.eu)", "datadoghq.eu"},
    {"AP1 (ap1.datadoghq.com)", "ap1.datadoghq.com"},
    {"AP2 (ap2.datadoghq.com)", "ap2.datadoghq.com"},
    {"US1-FED (ddog-gov.com)", "ddog-gov.com"}
  ]

  @select_type_classes [
    "flex items-center w-full p-4 rounded border transition-colors cursor-pointer",
    "border-border bg-surface",
    "hover:bg-raised hover:border-border-emphasis"
  ]

  @streams ~w[change session api_request flow]

  @common_fields ~w[name is_disabled disabled_reason error_message errored_at error_email_count
                    enabled_streams retroactive]a

  @fields %{
    Splunk.LogSink => @common_fields ++ ~w[collector_url hec_token index]a,
    Datadog.LogSink => @common_fields ++ ~w[site api_key tags]a,
    NewRelic.LogSink => @common_fields ++ ~w[region license_key]a,
    Elastic.LogSink => @common_fields ++ ~w[endpoint_url api_key data_stream]a,
    Sentinel.LogSink => @common_fields ++ ~w[tenant_id ingestion_endpoint dcr_immutable_id stream_name]a,
    S3.LogSink => @common_fields ++ ~w[bucket region role_arn key_prefix]a
  }

  @newrelic_region_options [
    {"US (log-api.newrelic.com)", "US"},
    {"EU (log-api.eu.newrelic.com)", "EU"},
    {"Japan (log-api.jp.nr-data.net)", "JP"},
    {"FedRAMP (gov-log-api.newrelic.com)", "FedRAMP"}
  ]

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Log Sinks",
        sentinel_setup_tab: "portal",
        s3_setup_tab: "console",
        trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?()
      )

    {:ok, init(socket, new: true)}
  end

  # New Log Sink
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @types do
    schema = Map.get(@modules, type)
    changeset = schema |> new_sink() |> changeset(%{})

    {:noreply,
     assign(socket,
       type: type,
       form: to_form(changeset),
       open_sink_actions_id: nil
     )}
  end

  # Edit Log Sink
  def handle_params(
        %{"type" => type, "id" => id},
        _url,
        %{assigns: %{live_action: :edit}} = socket
      )
      when type in @types do
    schema = Map.get(@modules, type)
    sink = Database.get_sink!(schema, id, socket.assigns.subject)
    changeset = changeset(sink, %{})

    {:noreply,
     assign(socket,
       sink: sink,
       sink_name: sink.name,
       type: type,
       form: to_form(changeset),
       open_sink_actions_id: nil
     )}
  end

  def handle_params(%{"type" => _type}, _url, _socket) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/log_sinks")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, socket)
      when socket.assigns.live_action in [:select_type, :new, :edit] do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/log_sinks")}
  end

  def handle_event("handle_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("sentinel_setup_tab", %{"tab" => tab}, socket)
      when tab in ~w[portal cli terraform] do
    {:noreply, assign(socket, sentinel_setup_tab: tab)}
  end

  def handle_event("s3_setup_tab", %{"tab" => tab}, socket)
      when tab in ~w[console cli terraform] do
    {:noreply, assign(socket, s3_setup_tab: tab)}
  end

  def handle_event("sentinel_admin_consent", _params, socket) do
    url = sentinel_admin_consent_url(socket.assigns.form, socket.assigns.account)
    {:noreply, push_event(socket, "open_url", %{url: url})}
  end

  def handle_event("validate", %{"log_sink" => attrs}, socket) do
    changeset = socket.assigns.form.source
    attrs = normalize_attrs(attrs, changeset)

    # EDIT: .data (original sink) so changes are relative to DB values.
    # NEW: apply_changes() to capture all current values.
    base =
      if socket.assigns.live_action == :edit do
        changeset.data
      else
        apply_changes(changeset)
      end

    changeset =
      base
      |> changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("submit_sink", _params, socket) do
    submit_sink(socket)
  end

  def handle_event("delete_sink", %{"id" => id}, socket) do
    sink = socket.assigns.log_sinks |> Enum.find(fn s -> s.id == id end)

    case Database.delete_sink(sink, socket.assigns.subject) do
      {:ok, _sink} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Log sink deleted successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/log_sinks")}

      {:error, reason} ->
        Logger.info("Failed to delete log sink: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to delete log sink.")}
    end
  end

  def handle_event("toggle_sink", %{"id" => id}, socket) do
    sink = socket.assigns.log_sinks |> Enum.find(fn s -> s.id == id end)
    new_disabled_state = not sink.is_disabled
    account = socket.assigns.account

    cond do
      new_disabled_state == false && sink.disabled_reason == "Sync error" ->
        {:noreply,
         put_flash(socket, :error, "Edit and save this log sink to re-enable it.")}

      new_disabled_state == false && not account.features.log_sinks ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Log sinks are available on the Enterprise plan. Please upgrade your plan."
         )}

      true ->
        changeset = toggle_sink_changeset(sink, new_disabled_state)
        action = if(new_disabled_state, do: "disabled", else: "enabled")

        case Database.update_sink(changeset, socket.assigns.subject) do
          {:ok, _sink} ->
            {:noreply,
             socket
             |> init()
             |> put_flash(:success, "Log sink #{action} successfully.")}

          {:error, reason} ->
            Logger.info("Failed to toggle log sink: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to update log sink.")}
        end
    end
  end

  def handle_event("sync_sink", %{"id" => id}, socket) do
    sink = socket.assigns.log_sinks |> Enum.find(fn s -> s.id == id end)

    cond do
      is_nil(sink) ->
        {:noreply, put_flash(socket, :error, "Failed to queue log sink delivery.")}

      not socket.assigns.account.features.log_sinks ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Log sinks are available on the Enterprise plan. Please upgrade your plan."
         )}

      true ->
        case Oban.insert(sync_module(sink).new(%{"log_sink_id" => sink.id})) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> init()
             |> put_flash(:success, "Log sink delivery has been queued successfully.")}

          {:error, reason} ->
            Logger.info("Failed to enqueue log sink sync job",
              id: sink.id,
              reason: inspect(reason)
            )

            {:noreply, put_flash(socket, :error, "Failed to queue log sink delivery.")}
        end
    end
  end

  def handle_event("toggle_sink_actions", %{"id" => id}, socket) do
    current = socket.assigns.open_sink_actions_id
    next = if current == id, do: nil, else: id

    {:noreply, assign(socket, open_sink_actions_id: next)}
  end

  def handle_event("close_sink_actions", _params, socket) do
    {:noreply, assign(socket, open_sink_actions_id: nil)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav
        account={@account}
        current_path={@current_path}
        trust_anchors_enabled?={@trust_anchors_enabled?}
      />

      <%= if Portal.Account.log_sinks_enabled?(@account) do %>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-semibold text-heading">Log Sinks</h2>
              <span class="text-xs text-subtle tabular-nums">
                {length(@log_sinks)}
              </span>
            </div>
            <div class="flex items-center gap-2">
              <.docs_action path="/log-sinks" />
              <.link
                patch={~p"/#{@account}/settings/log_sinks/new"}
                class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
              >
                <.icon name="ri-add-line" class="w-3 h-3" /> Add
              </.link>
            </div>
          </div>

          <div class="flex-1 overflow-auto">
            <%= if Enum.empty?(@log_sinks) do %>
              <div class="flex flex-col items-center justify-center h-full gap-3 text-subtle">
                <p class="text-sm">No log sinks configured.</p>
                <.link
                  patch={~p"/#{@account}/settings/log_sinks/new"}
                  class="flex items-center gap-1 px-2.5 py-1 rounded text-xs border border-border-strong text-body hover:text-heading hover:border-border-emphasis bg-surface transition-colors"
                >
                  <.icon name="ri-add-line" class="w-3 h-3" /> Add a log sink
                </.link>
              </div>
            <% else %>
              <table class="w-full text-sm border-collapse">
                <thead class="sticky top-0 z-10 bg-raised">
                  <tr class="border-b border-border-strong">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                      Log Sink
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Status
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-48">
                      Destination
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Delivered
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Backfill
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-40">
                      Last Delivery
                    </th>
                    <th class="px-6 py-2.5 w-14"></th>
                  </tr>
                </thead>
                <tbody>
                  <.sink_row
                    :for={sink <- @log_sinks}
                    type={sink_type(sink)}
                    account={@account}
                    sink={sink}
                    open_sink_actions_id={@open_sink_actions_id}
                  />
                </tbody>
              </table>
            <% end %>
          </div>
        </div>

    <!-- Add Log Sink Panel -->
        <div
          id="add-log-sink-panel"
          class={[
            "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
            "bg-elevated border-l border-border-strong",
            "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
            "transition-transform duration-200 ease-in-out",
            (@live_action in [:select_type, :new] && "translate-x-0") || "translate-x-full"
          ]}
          phx-window-keydown="handle_keydown"
          phx-key="Escape"
        >
          <!-- Select Log Sink Type -->
          <div :if={@live_action == :select_type} class="flex flex-col h-full overflow-hidden">
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
              <h2 class="text-sm font-semibold text-heading">Select Log Sink Type</h2>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <p class="mb-4 text-xs text-subtle">
                Select a destination to stream your logs to:
              </p>
              <ul class="flex flex-col gap-2">
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/splunk/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="splunk" size="xl" />
                      <span class="text-sm font-medium text-heading">Splunk</span>
                    </span>
                    <span class="text-xs text-body">
                      Stream logs to a Splunk HTTP Event Collector.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/datadog/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="datadog" size="xl" />
                      <span class="text-sm font-medium text-heading">Datadog</span>
                    </span>
                    <span class="text-xs text-body">
                      Stream logs to Datadog Log Management.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/newrelic/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="newrelic" size="xl" />
                      <span class="text-sm font-medium text-heading">New Relic</span>
                    </span>
                    <span class="text-xs text-body">
                      Stream logs to the New Relic Log API.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/elastic/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="elastic" size="xl" />
                      <span class="text-sm font-medium text-heading">Elastic</span>
                    </span>
                    <span class="text-xs text-body">
                      Index logs into Elasticsearch or any compatible cluster.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/sentinel/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="sentinel" size="xl" />
                      <span class="text-sm font-medium text-heading">Microsoft Sentinel</span>
                    </span>
                    <span class="text-xs text-body">
                      Stream logs to Microsoft Sentinel via the Azure Monitor Logs Ingestion API.
                    </span>
                  </.link>
                </li>
                <li>
                  <.link
                    patch={~p"/#{@account}/settings/log_sinks/s3/new"}
                    class={select_type_classes()}
                  >
                    <span class="flex items-center gap-3 w-2/5 shrink-0">
                      <.provider_icon provider="s3" size="xl" />
                      <span class="text-sm font-medium text-heading">Amazon S3</span>
                    </span>
                    <span class="text-xs text-body">
                      Archive logs to an Amazon S3 bucket as NDJSON objects.
                    </span>
                  </.link>
                </li>
              </ul>
            </div>
          </div>

    <!-- New Log Sink Form -->
          <div
            :if={@live_action == :new and assigns[:form] != nil}
            class="flex flex-col h-full overflow-hidden"
          >
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
              <div class="flex items-center gap-2">
                <.link
                  patch={~p"/#{@account}/settings/log_sinks/new"}
                  class="flex items-center justify-center w-6 h-6 rounded text-subtle hover:text-heading hover:bg-raised transition-colors"
                  title="Back"
                >
                  <.icon name="ri-arrow-left-line" class="w-4 h-4" />
                </.link>
                <div class="flex items-center gap-2">
                  <.provider_icon provider={@type} size="md" />
                  <h2 class="text-sm font-semibold text-heading">
                    Add {titleize(@type)} Log Sink
                  </h2>
                  <.docs_action path={"/log-sinks/#{@type}"} />
                </div>
              </div>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <.sink_form form={@form} type={@type} live_action={@live_action} account={@account} sentinel_setup_tab={@sentinel_setup_tab} s3_setup_tab={@s3_setup_tab} />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-border">
              <.button phx-click="close_panel">
                Cancel
              </.button>
              <.button
                form="log-sink-form"
                type="submit"
                style="primary"
                disabled={not @form.source.valid?}
              >
                Create
              </.button>
            </div>
          </div>
        </div>

    <!-- Edit Log Sink Panel -->
        <div
          id="edit-log-sink-panel"
          class={[
            "fixed top-14 right-0 bottom-0 z-20 flex flex-col w-full lg:w-3/4 xl:w-1/2",
            "bg-elevated border-l border-border-strong",
            "shadow-[-4px_0px_20px_rgba(0,0,0,0.07)]",
            "transition-transform duration-200 ease-in-out",
            (@live_action == :edit && assigns[:form] != nil && "translate-x-0") || "translate-x-full"
          ]}
          phx-window-keydown="handle_keydown"
          phx-key="Escape"
        >
          <div
            :if={@live_action == :edit and assigns[:form] != nil}
            class="flex flex-col h-full overflow-hidden"
          >
            <div class="shrink-0 flex items-center justify-between px-5 py-4 border-b border-border">
              <div class="flex items-center gap-2">
                <.provider_icon provider={@type} size="md" />
                <h2 class="text-sm font-semibold text-heading">
                  Edit {assigns[:sink_name]}
                </h2>
                <.docs_action path={"/log-sinks/#{@type}"} />
              </div>
              <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
            </div>
            <div class="flex-1 overflow-y-auto px-5 py-4">
              <.flash :if={assigns[:sink] && @sink.error_message} kind={:error} class="mb-4">
                {@sink.error_message}
              </.flash>
              <.sink_form form={@form} type={@type} live_action={@live_action} account={@account} sentinel_setup_tab={@sentinel_setup_tab} s3_setup_tab={@s3_setup_tab} />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-border">
              <.button phx-click="close_panel">
                Cancel
              </.button>
              <.button
                form="log-sink-form"
                type="submit"
                style="primary"
                disabled={not @form.source.valid?}
              >
                Save
              </.button>
            </div>
          </div>
        </div>
      <% else %>
        <div class="flex-1 flex flex-col overflow-hidden">
          <div class="flex items-center justify-between px-6 py-3 border-b border-border shrink-0">
            <div class="flex items-center gap-2">
              <h2 class="text-xs font-semibold text-heading">Log Sinks</h2>
            </div>
            <div class="flex items-center gap-2">
              <.docs_action path="/log-sinks" />
            </div>
          </div>

          <div class="flex-1 overflow-hidden relative">
            <div class="blur-xs pointer-events-none select-none opacity-60">
              <table class="w-full text-sm border-collapse">
                <thead class="bg-raised">
                  <tr class="border-b border-border-strong">
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-64">
                      Log Sink
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Status
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-48">
                      Destination
                    </th>
                    <th class="px-6 py-2.5 text-left text-[10px] font-semibold tracking-widest uppercase text-subtle w-28">
                      Delivered
                    </th>
                    <th class="px-6 py-2.5 w-14"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr class="border-b border-border">
                    <td class="px-6 py-3">
                      <div class="flex items-center gap-3">
                        <.provider_icon provider="splunk" size="lg" />
                        <span class="text-sm font-medium text-heading">SOC Splunk</span>
                      </div>
                    </td>
                    <td class="px-6 py-3 w-28">
                      <span class="inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400">
                        Active
                      </span>
                    </td>
                    <td class="px-6 py-3 w-48">
                      <span class="text-sm text-body font-mono">acme.splunkcloud.com</span>
                    </td>
                    <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">1,284,113</td>
                    <td class="px-6 py-3 w-14"></td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="absolute inset-0 flex items-end justify-center pb-[20%]">
              <div class="flex flex-col items-center gap-3 bg-elevated border border-border rounded-lg shadow-lg px-8 py-6 text-subtle">
                <.icon name="ri-upload-cloud-2-line" class="w-8 h-8" />
                <div class="flex flex-col items-center gap-1 text-center">
                  <p class="text-sm font-medium text-heading">
                    Stream Logs to Your SIEM
                  </p>
                  <p class="text-xs">
                    Deliver audit, session, API, and flow logs to destinations like Splunk.
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
      <% end %>
    </div>
    """
  end

  attr :type, :string, required: true
  attr :account, :any, required: true
  attr :sink, :any, required: true
  attr :open_sink_actions_id, :string, default: nil

  defp sink_row(assigns) do
    toggle_disabled = assigns.sink.is_disabled and not assigns.account.features.log_sinks
    assigns = assign(assigns, toggle_disabled: toggle_disabled)

    ~H"""
    <tr class="border-b border-border hover:bg-raised">
      <td class="px-6 py-3">
        <div class="flex items-center gap-3">
          <.provider_icon provider={@type} size="lg" />
          <div class="min-w-0">
            <span class="text-sm font-medium text-heading truncate" title={@sink.name}>
              {@sink.name}
            </span>
            <span class="block text-xs text-subtle font-mono">{@sink.id}</span>
          </div>
        </div>
      </td>
      <td class="px-6 py-3 w-28">
        <.sink_status_badge sink={@sink} />
      </td>
      <td class="px-6 py-3 w-48">
        <span class="text-sm text-body font-mono truncate block" title={sink_destination(@sink)}>
          {sink_destination(@sink)}
        </span>
      </td>
      <td class="px-6 py-3 w-28 text-sm text-heading tabular-nums">
        {delivered_count(@sink)}
      </td>
      <td class="px-6 py-3 w-28 text-xs text-body tabular-nums">
        {backfill_status(@sink)}
      </td>
      <td class="px-6 py-3 w-40">
        <%= if last_delivery_at(@sink) do %>
          <span class="text-xs text-body">
            <.relative_datetime datetime={last_delivery_at(@sink)} />
          </span>
        <% else %>
          <span class="text-xs text-subtle">Never</span>
        <% end %>
      </td>
      <td class="px-6 py-3 w-14">
        <div class="flex justify-end">
          <.actions_dropdown
            open={@open_sink_actions_id == @sink.id}
            close_event="close_sink_actions"
            phx-click="toggle_sink_actions"
            phx-value-id={@sink.id}
          >
            <.link
              patch={~p"/#{@account}/settings/log_sinks/#{@type}/#{@sink.id}/edit"}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body"
            >
              <.icon name="ri-pencil-line" class="w-3.5 h-3.5 shrink-0" /> Edit
            </.link>
            <button
              type="button"
              phx-click="sync_sink"
              phx-value-id={@sink.id}
              disabled={@sink.is_disabled}
              class="flex items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body disabled:opacity-50 disabled:cursor-not-allowed"
            >
              <.icon name="ri-loop-left-line" class="w-3.5 h-3.5 shrink-0" /> Deliver Now
            </button>
            <div class="my-1 border-t border-border"></div>
            <.button_with_confirmation
              :if={@sink.disabled_reason != "Sync error"}
              id={"toggle-sink-#{@sink.id}"}
              on_confirm="toggle_sink"
              on_confirm_id={@sink.id}
              class="flex justify-start items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-body border-0 bg-transparent"
            >
              <.icon
                name={
                  if @sink.is_disabled,
                    do: "ri-checkbox-circle-line",
                    else: "ri-close-circle-line"
                }
                class="w-3.5 h-3.5 shrink-0"
              />
              {if @sink.is_disabled, do: "Enable", else: "Disable"}
              <:dialog_title>
                {if @sink.is_disabled, do: "Enable", else: "Disable"} Log Sink
              </:dialog_title>
              <:dialog_content>
                <p>
                  Are you sure you want to {if @sink.is_disabled,
                    do: "enable",
                    else: "disable"} <strong>{@sink.name}</strong>?
                </p>
                <%= if not @sink.is_disabled do %>
                  <p class="mt-2">
                    Logs will not be delivered while disabled, and logs that expire from
                    retention in the meantime are not recoverable.
                  </p>
                <% end %>
              </:dialog_content>
              <:dialog_confirm_button>
                {if @sink.is_disabled, do: "Enable", else: "Disable"}
              </:dialog_confirm_button>
              <:dialog_cancel_button>Cancel</:dialog_cancel_button>
            </.button_with_confirmation>
            <div class="my-1 border-t border-border"></div>
            <.button_with_confirmation
              id={"delete-sink-#{@sink.id}"}
              on_confirm="delete_sink"
              on_confirm_id={@sink.id}
              class="flex justify-start items-center gap-2.5 w-full px-3 py-2 text-xs text-left hover:bg-raised transition-colors text-error border-0 bg-transparent"
            >
              <.icon name="ri-delete-bin-line" class="w-3.5 h-3.5 shrink-0" /> Delete
              <:dialog_title>Delete Log Sink</:dialog_title>
              <:dialog_content>
                <p>
                  Are you sure you want to delete <strong>{@sink.name}</strong>?
                  Delivery state is deleted with it; re-creating the sink starts over.
                </p>
              </:dialog_content>
              <:dialog_confirm_button>Delete</:dialog_confirm_button>
              <:dialog_cancel_button>Cancel</:dialog_cancel_button>
            </.button_with_confirmation>
          </.actions_dropdown>
        </div>
      </td>
    </tr>
    """
  end

  attr :sink, :any, required: true

  defp sink_status_badge(assigns) do
    ~H"""
    <%= cond do %>
      <% @sink.is_disabled and @sink.disabled_reason == "Sync error" -> %>
        <.status_popover id={"sink-status-#{@sink.id}"} label="Error" color="red">
          <p class="text-xs text-body break-words">{@sink.error_message}</p>
          <p class="mt-2 text-xs text-subtle">
            Delivery is stopped. Edit and Save this log sink to re-enable it.
          </p>
        </.status_popover>
      <% @sink.is_disabled -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-raised text-subtle">
          Disabled
        </span>
      <% @sink.errored_at -> %>
        <.status_popover id={"sink-status-#{@sink.id}"} label="Warning" color="yellow">
          <p class="text-xs text-body break-words">{@sink.error_message}</p>
          <p class="mt-2 text-xs text-subtle">
            Delivery is retried automatically. The sink is disabled if failures
            persist for 24 hours.
          </p>
        </.status_popover>
      <% true -> %>
        <span class="inline-flex items-center text-[10px] font-semibold px-1.5 py-0.5 rounded bg-green-100 text-green-700">
          Active
        </span>
    <% end %>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :color, :string, required: true
  slot :inner_block, required: true

  defp status_popover(assigns) do
    ~H"""
    <button
      type="button"
      id={"#{@id}-button"}
      phx-hook="Popover"
      data-popover-target-id={@id}
      data-popover-trigger="click"
      data-popover-placement="bottom"
      class={[
        "inline-flex items-center gap-1 text-[10px] font-semibold px-1.5 py-0.5 rounded cursor-pointer",
        @color == "red" && "bg-red-100 text-red-700",
        @color == "yellow" && "bg-yellow-100 text-yellow-700"
      ]}
    >
      {@label} <.icon name="ri-information-line" class="w-3 h-3" />
    </button>
    <div
      id={@id}
      class="invisible opacity-0 fixed z-50 w-80 p-3 text-left bg-elevated rounded shadow-sm border border-border"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :form, :any, required: true
  attr :type, :string, required: true
  attr :live_action, :atom, required: true
  attr :account, :any, required: true
  attr :sentinel_setup_tab, :string, required: true
  attr :s3_setup_tab, :string, required: true

  defp sink_form(assigns) do
    ~H"""
    <.form
      id="log-sink-form"
      for={@form}
      phx-change="validate"
      phx-submit="submit_sink"
    >
      <div class="space-y-6">
        <div>
          <label for={@form[:name].id} class="block text-xs font-medium text-body mb-1.5">
            Name <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:name]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            Enter a name to identify this log sink.
          </p>
        </div>

        <div :if={@type == "splunk"}>
          <label for={@form[:collector_url].id} class="block text-xs font-medium text-body mb-1.5">
            HEC URL <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:collector_url]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The base URL of your Splunk HTTP Event Collector, e.g.
            <code class="text-xs">https://http-inputs-acme.splunkcloud.com</code>.
          </p>
        </div>

        <div :if={@type == "splunk"}>
          <label for={@form[:hec_token].id} class="block text-xs font-medium text-body mb-1.5">
            HEC Token <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:hec_token]}
            type="password"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The HTTP Event Collector token to authenticate with.
          </p>
        </div>

        <div :if={@type == "splunk"}>
          <label for={@form[:index].id} class="block text-xs font-medium text-body mb-1.5">
            Index
          </label>
          <.input
            field={@form[:index]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
          />
          <p class="mt-1 text-xs text-subtle">
            Optional. The Splunk index to send events to; the token's default index is used
            when left blank.
          </p>
        </div>

        <div :if={@type == "datadog"}>
          <.input
            field={@form[:site]}
            type="select"
            label="Site"
            options={datadog_site_options()}
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The Datadog site your organization uses; shown under Organization Settings in Datadog.
          </p>
        </div>

        <div :if={@type == "datadog"}>
          <label for={@form[:api_key].id} class="block text-xs font-medium text-body mb-1.5">
            API Key <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:api_key]}
            type="password"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            A Datadog API key with log ingestion permission.
          </p>
        </div>

        <div :if={@type == "datadog"}>
          <label for={@form[:tags].id} class="block text-xs font-medium text-body mb-1.5">
            Tags
          </label>
          <.input
            field={@form[:tags]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
          />
          <p class="mt-1 text-xs text-subtle">
            Optional. Comma-separated tags added to every event, e.g.
            <code class="text-xs">env:prod,team:secops</code>. A
            <code class="text-xs">stream:&lt;stream&gt;</code>
            tag is always included.
          </p>
        </div>

        <div :if={@type == "newrelic"}>
          <.input
            field={@form[:region]}
            type="select"
            label="Region"
            options={newrelic_region_options()}
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The region your New Relic account reports to.
          </p>
        </div>

        <div :if={@type == "newrelic"}>
          <label for={@form[:license_key].id} class="block text-xs font-medium text-body mb-1.5">
            License Key <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:license_key]}
            type="password"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            A New Relic license key (ingest key) to authenticate with.
          </p>
        </div>

        <div :if={@type == "elastic"}>
          <label for={@form[:endpoint_url].id} class="block text-xs font-medium text-body mb-1.5">
            Endpoint URL <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:endpoint_url]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            Your cluster's Elasticsearch endpoint, e.g.
            <code class="text-xs">https://my-deployment.es.us-east-1.aws.elastic-cloud.com</code>.
            OpenSearch and other compatible clusters work too.
          </p>
        </div>

        <div :if={@type == "elastic"}>
          <label for={@form[:api_key].id} class="block text-xs font-medium text-body mb-1.5">
            API Key <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:api_key]}
            type="password"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            A base64-encoded Elasticsearch API key with permission to manage index
            templates and write to the data stream.
          </p>
        </div>

        <div :if={@type == "elastic"}>
          <label for={@form[:data_stream].id} class="block text-xs font-medium text-body mb-1.5">
            Data stream <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:data_stream]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The data stream to append events to. Firezone creates it on first
            delivery; manage retention with the stream's lifecycle in Kibana.
          </p>
        </div>

        <div :if={@type == "sentinel"} class="p-3 rounded border border-border bg-raised">
          <p class="text-xs font-medium text-heading mb-3">Setup</p>

          <div class="mb-4 p-3 rounded border border-border bg-surface">
            <p class="text-xs font-medium text-heading mb-1.5">1. Grant admin consent</p>
            <p class="text-xs text-subtle mb-3">
              Enter your Microsoft Entra tenant ID below, then have a tenant administrator grant
              consent. This adds the <strong>Firezone Sentinel Log Ingestion</strong> application
              to your tenant so you can assign it a role in the next step. It requests no API
              permissions and cannot read your directory or data. It only becomes a service
              principal you grant the Monitoring Metrics Publisher role to on a single data
              collection rule.
            </p>
            <.button
              type="button"
              style="primary"
              icon="ri-external-link-line"
              id="sentinel-consent-link"
              phx-click="sentinel_admin_consent"
              phx-hook="OpenURL"
            >
              Grant admin consent
            </.button>
          </div>

          <p class="text-xs font-medium text-heading mb-1.5">2. Create the ingestion resources</p>
          <p class="text-xs text-subtle mb-3">
            Create a data collection endpoint, a custom table, and a data collection rule, then
            grant the Firezone application the Monitoring Metrics Publisher role on the rule.
          </p>
          <div class="flex border-b border-border mb-3" role="tablist">
            <button
              :for={{tab, label, icon} <- [{"portal", "Azure Portal", "ri-window-line"}, {"cli", "Azure CLI", "ri-terminal-line"}, {"terraform", "Terraform", "ri-stack-line"}]}
              type="button"
              role="tab"
              phx-click="sentinel_setup_tab"
              phx-value-tab={tab}
              class={[
                "flex items-center gap-1.5 px-4 py-2 text-xs font-medium border-b-2 -mb-px whitespace-nowrap transition-colors",
                @sentinel_setup_tab == tab && "border-brand text-brand",
                @sentinel_setup_tab != tab &&
                  "border-transparent text-body hover:text-heading hover:border-border-strong"
              ]}
            >
              <.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
              {label}
            </button>
          </div>
          <ol
            :if={@sentinel_setup_tab == "portal"}
            class="list-decimal ml-4 space-y-1.5 text-xs text-subtle"
          >
            <li>
              You need a Log Analytics workspace: use the one Microsoft Sentinel is enabled
              on. If you don't have one yet, search for
              <strong>Log Analytics workspaces</strong> in the Azure portal and create one,
              then search for <strong>Microsoft Sentinel</strong>, choose
              <strong>Create</strong>, and add it to that workspace.
            </li>
            <li>
              Search for <strong>Data collection endpoints</strong> in the Azure portal and
              create one in the same region as your workspace. Firezone delivers logs to
              this endpoint.
            </li>
            <li>
              Open your workspace and go to <strong>Settings &rarr; Tables</strong>. Choose
              <strong>Create &rarr; New custom log (DCR-based)</strong>. Name the table
              <code class="text-xs">FirezoneLogs</code>, choose
              <strong>Create a new data collection rule</strong> and give it a name (e.g.
              <code class="text-xs">firezone-logs</code>), and select the data collection
              endpoint from the previous step. On the
              <strong>Schema and transformation</strong> step, upload
              <a
                href={~p"/downloads/firezone-sentinel-sample.json"}
                download
                class="underline hover:text-heading"
              >
                this sample file
              </a>
              and keep the default transformation, then create the table.
            </li>
            <li>
              Search for <strong>Data collection rules</strong>, open the rule you just
              created, and go to <strong>Access control (IAM)</strong>. Choose
              <strong>Add &rarr; Add role assignment</strong>, select the
              <strong>Monitoring Metrics Publisher</strong> role, then under
              <strong>Members</strong> choose <strong>User, group, or service principal</strong>
              and select the <strong>Firezone Sentinel Log Ingestion</strong> application
              (created by the admin consent above). Review and assign. The assignment can
              take up to 30 minutes to take effect.
            </li>
            <li>
              Fill in the fields below. Each field's hint says where to find its value in
              the Azure portal; if you followed these steps, the stream name is
              <code class="text-xs">Custom-FirezoneLogs_CL</code>.
            </li>
          </ol>
          <div :if={@sentinel_setup_tab == "cli"}>
            <p class="text-xs text-subtle mb-2">
              Assumes an existing Log Analytics workspace. Set the variables for your
              environment, then run the script with the Azure CLI logged into your
              subscription. It prints the values for the fields below.
            </p>
            <.code_block id="sentinel-setup-cli" class="rounded text-xs">{sentinel_cli_snippet()}</.code_block>
          </div>
          <div :if={@sentinel_setup_tab == "terraform"}>
            <p class="text-xs text-subtle mb-2">
              Assumes an existing Log Analytics workspace and requires the azurerm, azuread,
              and azapi providers. The outputs are the values for the fields below.
            </p>
            <.code_block id="sentinel-setup-terraform" class="rounded text-xs">{sentinel_terraform_snippet()}</.code_block>
          </div>
        </div>

        <div :if={@type == "sentinel"}>
          <label for={@form[:tenant_id].id} class="block text-xs font-medium text-body mb-1.5">
            Tenant ID <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:tenant_id]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            Your Microsoft Entra directory (tenant) ID, e.g.
            <code class="text-xs">00000000-0000-0000-0000-000000000000</code>.
          </p>
        </div>

        <div :if={@type == "sentinel"}>
          <label
            for={@form[:ingestion_endpoint].id}
            class="block text-xs font-medium text-body mb-1.5"
          >
            Ingestion Endpoint <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:ingestion_endpoint]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The <strong>Logs Ingestion</strong> URI shown on your data collection endpoint's
            Overview page, e.g.
            <code class="text-xs">https://my-dce-abcd.eastus-1.ingest.monitor.azure.com</code>.
          </p>
        </div>

        <div :if={@type == "sentinel"}>
          <label
            for={@form[:dcr_immutable_id].id}
            class="block text-xs font-medium text-body mb-1.5"
          >
            DCR Immutable ID <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:dcr_immutable_id]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The <strong>Immutable Id</strong> shown on the data collection rule's Overview
            page (also in its <strong>JSON View</strong>), e.g.
            <code class="text-xs">dcr-0123456789abcdef0123456789abcdef</code>.
          </p>
        </div>

        <div :if={@type == "sentinel"}>
          <label for={@form[:stream_name].id} class="block text-xs font-medium text-body mb-1.5">
            Stream Name <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:stream_name]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The DCR's input stream, listed in its <strong>JSON View</strong> under
            <code class="text-xs">streamDeclarations</code>. The Azure portal wizard names it
            <code class="text-xs">Custom-&lt;table&gt;_CL</code>, e.g.
            <code class="text-xs">Custom-FirezoneLogs_CL</code>.
          </p>
        </div>

        <div :if={@type == "s3"} class="p-3 rounded border border-border bg-raised">
          <p class="text-xs font-medium text-heading mb-2">Setup</p>
          <p class="text-xs text-subtle mb-3">
            Firezone assumes an IAM role in your AWS account to write log objects. The
            trust policy and snippets below are pinned to this sink's External ID, so
            complete setup and save without leaving this page:
          </p>
          <div class="flex border-b border-border mb-3" role="tablist">
            <button
              :for={{tab, label, icon} <- [{"console", "AWS Console", "ri-window-line"}, {"cli", "AWS CLI", "ri-terminal-line"}, {"terraform", "Terraform", "ri-stack-line"}]}
              type="button"
              role="tab"
              phx-click="s3_setup_tab"
              phx-value-tab={tab}
              class={[
                "flex items-center gap-1.5 px-4 py-2 text-xs font-medium border-b-2 -mb-px whitespace-nowrap transition-colors",
                @s3_setup_tab == tab && "border-brand text-brand",
                @s3_setup_tab != tab &&
                  "border-transparent text-body hover:text-heading hover:border-border-strong"
              ]}
            >
              <.icon name={icon} class="w-3.5 h-3.5 shrink-0" />
              {label}
            </button>
          </div>
          <ol
            :if={@s3_setup_tab == "console"}
            class="list-decimal ml-4 space-y-1.5 text-xs text-subtle"
          >
            <li>
              In the S3 console, create a bucket (or pick an existing one) and note its
              region.
            </li>
            <li>
              In IAM under <strong>Roles</strong>, choose
              <strong>Create role &rarr; Custom trust policy</strong> and paste:
              <pre class="mt-2 mb-1 p-3 rounded border border-border bg-surface text-xs text-body overflow-x-auto"><code>{trust_policy_json(@form)}</code></pre>
              Continue without adding permissions and give the role a name, e.g.
              <code class="text-xs">firezone-logs</code>.
            </li>
            <li>
              On the new role, choose
              <strong>Add permissions &rarr; Create inline policy &rarr; JSON</strong>
              and paste:
              <pre class="mt-2 mb-1 p-3 rounded border border-border bg-surface text-xs text-body overflow-x-auto"><code>{s3_permission_policy_json(@form)}</code></pre>
            </li>
            <li>
              Fill in the fields below: the bucket name, its region, and the role's ARN
              (shown at the top of the role's page).
            </li>
          </ol>
          <div :if={@s3_setup_tab == "cli"}>
            <p class="text-xs text-subtle mb-2">
              Set the variables, then run the script with the AWS CLI logged into your
              account. It prints the Role ARN for the field below.
            </p>
            <.code_block id="s3-setup-cli" class="rounded text-xs">{s3_cli_snippet(@form)}</.code_block>
          </div>
          <div :if={@s3_setup_tab == "terraform"}>
            <p class="text-xs text-subtle mb-2">
              Requires the aws provider; the bucket is created in the provider's region.
              The output is the Role ARN for the field below.
            </p>
            <.code_block id="s3-setup-terraform" class="rounded text-xs">{s3_terraform_snippet(@form)}</.code_block>
          </div>
        </div>

        <div :if={@type == "s3"}>
          <label for={@form[:bucket].id} class="block text-xs font-medium text-body mb-1.5">
            Bucket <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:bucket]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The name of the S3 bucket to write log objects to.
          </p>
        </div>

        <div :if={@type == "s3"}>
          <label for={@form[:region].id} class="block text-xs font-medium text-body mb-1.5">
            Region <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:region]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The AWS region the bucket is in, e.g. <code class="text-xs">us-east-1</code>.
          </p>
        </div>

        <div :if={@type == "s3"}>
          <label for={@form[:role_arn].id} class="block text-xs font-medium text-body mb-1.5">
            Role ARN <span class="text-error">*</span>
          </label>
          <.input
            field={@form[:role_arn]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
            required
          />
          <p class="mt-1 text-xs text-subtle">
            The IAM role in your AWS account that Firezone assumes to write objects,
            e.g. <code class="text-xs">arn:aws:iam::123456789012:role/firezone-logs</code>.
          </p>
        </div>

        <div :if={@type == "s3"}>
          <label for={@form[:key_prefix].id} class="block text-xs font-medium text-body mb-1.5">
            Key Prefix
          </label>
          <.input
            field={@form[:key_prefix]}
            type="text"
            autocomplete="off"
            phx-debounce="300"
            data-1p-ignore
          />
          <p class="mt-1 text-xs text-subtle">
            Optional. A prefix added to every object key, e.g.
            <code class="text-xs">firezone/logs</code>.
          </p>
        </div>

        <div :if={@type == "s3"}>
          <span class="block text-xs font-medium text-body mb-1.5">External ID</span>
          <p class="text-sm font-mono text-heading">
            {get_field(@form.source, :external_id)}
          </p>
          <p class="mt-1 text-xs text-subtle">
            Generated by Firezone and pinned to this sink. The role's trust policy must
            require it via <code class="text-xs">sts:ExternalId</code>.
          </p>
        </div>

        <fieldset>
          <legend class="block text-xs font-medium text-body mb-3">
            Log streams
          </legend>
          <input type="hidden" name={@form[:enabled_streams].name <> "[]"} value="" />
          <div class="grid gap-2 md:grid-cols-2">
            <label
              :for={stream <- streams()}
              class="flex items-center gap-3 p-3 border border-border rounded cursor-pointer hover:border-border-emphasis transition-colors"
            >
              <input
                type="checkbox"
                name={@form[:enabled_streams].name <> "[]"}
                value={stream}
                checked={stream_enabled?(@form, stream)}
                class="w-4 h-4 text-brand border-border rounded"
              />
              <span class="flex flex-col">
                <span class="text-sm font-medium text-heading">{stream_label(stream)}</span>
                <span class="text-xs text-subtle">{stream_help(stream)}</span>
              </span>
            </label>
          </div>
        </fieldset>

        <div :if={@live_action == :new}>
          <label class="flex items-center gap-3 cursor-pointer">
            <input type="hidden" name={@form[:retroactive].name} value="false" />
            <input
              type="checkbox"
              name={@form[:retroactive].name}
              value="true"
              checked={get_field(@form.source, :retroactive)}
              class="w-4 h-4 text-brand border-border rounded"
            />
            <span class="text-sm font-medium text-heading">
              Deliver existing logs
            </span>
          </label>
          <p class="mt-1 ml-7 text-xs text-subtle">
            Backfill logs recorded before this sink was created, oldest first, while new
            logs are delivered as they arrive. When disabled, only logs recorded from now
            on are delivered.
          </p>
          <p :if={@type == "newrelic"} class="mt-1 ml-7 text-xs text-subtle">
            New Relic drops payloads with timestamps older than 48 hours, so backfilled
            events older than that will not appear in New Relic.
          </p>
        </div>
      </div>
    </.form>
    """
  end

  defp submit_sink(%{assigns: %{live_action: :new, form: %{source: changeset}}} = socket) do
    changeset = put_sink_assoc(changeset, socket)

    changeset
    |> Database.insert_sink(socket.assigns.subject)
    |> handle_submit(socket, "created")
  end

  defp submit_sink(
         %{assigns: %{live_action: :edit, form: %{source: changeset}, sink: sink}} = socket
       ) do
    changeset
    |> maybe_clear_sync_error(sink)
    |> Database.update_sink(socket.assigns.subject)
    |> handle_submit(socket, "updated")
  end

  defp handle_submit(result, socket, verb) do
    case result do
      {:ok, _sink} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:success, "Log sink #{verb} successfully.")
         |> push_patch(to: ~p"/#{socket.assigns.account}/settings/log_sinks")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp put_sink_assoc(changeset, socket) do
    schema = changeset.data.__struct__
    account_id = socket.assigns.subject.account.id

    type =
      case schema do
        Splunk.LogSink -> :splunk
        Datadog.LogSink -> :datadog
        NewRelic.LogSink -> :newrelic
        Elastic.LogSink -> :elastic
        Sentinel.LogSink -> :sentinel
        S3.LogSink -> :s3
      end

    log_sink_id = Ecto.UUID.generate()

    log_sink_changeset =
      %Portal.LogSink{}
      |> Ecto.Changeset.change(%{
        id: log_sink_id,
        account_id: account_id,
        type: type
      })

    changeset
    |> put_change(:id, log_sink_id)
    |> put_assoc(:log_sink, log_sink_changeset)
  end

  # Editing is the ONLY way out of an error-disabled state: the sink is
  # presumably being edited to fix the problem, so re-enable it and let the
  # next delivery prove the fix.
  defp sync_module(%Splunk.LogSink{}), do: Splunk.Sync
  defp sync_module(%Datadog.LogSink{}), do: Datadog.Sync
  defp sync_module(%NewRelic.LogSink{}), do: NewRelic.Sync
  defp sync_module(%Elastic.LogSink{}), do: Elastic.Sync
  defp sync_module(%Sentinel.LogSink{}), do: Sentinel.Sync
  defp sync_module(%S3.LogSink{}), do: S3.Sync

  defp maybe_clear_sync_error(changeset, sink) do
    if sink.disabled_reason == "Sync error" do
      changeset
      |> put_change(:is_disabled, false)
      |> put_change(:disabled_reason, nil)
      |> put_change(:error_message, nil)
      |> put_change(:errored_at, nil)
      |> put_change(:error_email_count, 0)
      |> put_change(:last_error_email_at, nil)
    else
      changeset
    end
  end

  defp toggle_sink_changeset(sink, true) do
    changeset(sink, %{
      "is_disabled" => true,
      "disabled_reason" => "Disabled by admin"
    })
  end

  defp toggle_sink_changeset(sink, false) do
    changeset(sink, %{
      "is_disabled" => false,
      "disabled_reason" => nil,
      "error_message" => nil,
      "errored_at" => nil,
      "error_email_count" => 0
    })
  end

  defp changeset(struct, attrs) do
    schema = struct.__struct__

    cast(struct, attrs, Map.get(@fields, schema))
    |> schema.changeset()
  end

  defp normalize_attrs(attrs, _changeset) do
    Map.update(attrs, "enabled_streams", [], fn streams ->
      streams |> List.wrap() |> Enum.reject(&(&1 == ""))
    end)
  end

  defp select_type_classes, do: @select_type_classes

  defp datadog_site_options, do: @datadog_site_options

  defp newrelic_region_options, do: @newrelic_region_options

  defp streams, do: @streams

  defp stream_enabled?(form, stream) do
    stream = String.to_existing_atom(stream)
    stream in (get_field(form.source, :enabled_streams) || [])
  end

  defp stream_label("change"), do: "Change logs"
  defp stream_label("session"), do: "Session logs"
  defp stream_label("api_request"), do: "API request logs"
  defp stream_label("flow"), do: "Flow logs"

  defp stream_help("change"), do: "Audit trail of configuration changes."
  defp stream_help("session"), do: "Client, gateway, and admin sign-ins."
  defp stream_help("api_request"), do: "REST API requests."
  defp stream_help("flow"), do: "Network flows through gateways."

  defp titleize("splunk"), do: "Splunk"
  defp titleize("datadog"), do: "Datadog"
  defp titleize("newrelic"), do: "New Relic"
  defp titleize("elastic"), do: "Elastic"
  defp titleize("sentinel"), do: "Microsoft Sentinel"
  defp titleize("s3"), do: "Amazon S3"

  defp sink_type(sink) do
    case sink.__struct__ do
      Splunk.LogSink -> "splunk"
      Datadog.LogSink -> "datadog"
      NewRelic.LogSink -> "newrelic"
      Elastic.LogSink -> "elastic"
      Sentinel.LogSink -> "sentinel"
      S3.LogSink -> "s3"
    end
  end

  defp sink_destination(%Splunk.LogSink{} = sink) do
    case URI.new(sink.collector_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) -> host
      _ -> sink.collector_url
    end
  end

  defp sink_destination(%Datadog.LogSink{} = sink), do: sink.site

  defp sink_destination(%NewRelic.LogSink{} = sink) do
    sink.region
    |> NewRelic.APIClient.endpoint()
    |> URI.parse()
    |> Map.get(:host)
  end

  defp sink_destination(%Elastic.LogSink{} = sink) do
    case URI.new(sink.endpoint_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) -> host
      _ -> sink.endpoint_url
    end
  end

  defp sink_destination(%Sentinel.LogSink{} = sink) do
    case URI.new(sink.ingestion_endpoint || "") do
      {:ok, %URI{host: host}} when is_binary(host) -> host
      _ -> sink.ingestion_endpoint
    end
  end

  defp sink_destination(%S3.LogSink{} = sink) do
    case sink.key_prefix do
      nil -> "s3://#{sink.bucket}"
      prefix -> "s3://#{sink.bucket}/#{prefix}"
    end
  end

  defp sentinel_admin_consent_url(form, account) do
    tenant =
      case get_field(form.source, :tenant_id) do
        tenant when is_binary(tenant) and tenant != "" -> String.trim(tenant)
        _ -> "organizations"
      end

    "https://login.microsoftonline.com/#{tenant}/adminconsent?" <>
      URI.encode_query(%{
        "client_id" => sentinel_client_id(),
        "redirect_uri" => url(~p"/auth/sentinel/consent"),
        "state" => Phoenix.Param.to_param(account)
      })
  end

  defp sentinel_client_id do
    Portal.Config.fetch_env!(:portal, Portal.Sentinel.APIClient)
    |> Keyword.get(:client_id)
    |> Kernel.||("<firezone-application-client-id>")
  end

  @sentinel_cli_snippet ~S"""
  RG="my-resource-group"
  WORKSPACE="my-workspace"
  LOCATION="eastus"

  WORKSPACE_ID=$(az monitor log-analytics workspace show \
    -g "$RG" -n "$WORKSPACE" --query id -o tsv)

  if ! az monitor log-analytics workspace table show \
       -g "$RG" --workspace-name "$WORKSPACE" -n FirezoneLogs_CL > /dev/null 2>&1; then
    az monitor log-analytics workspace table create \
      -g "$RG" --workspace-name "$WORKSPACE" -n FirezoneLogs_CL \
      --columns TimeGenerated=datetime Message=string Stream=string Firezone=dynamic \
      --output none
  fi

  DCE_ID=$(az monitor data-collection endpoint show \
    -g "$RG" -n firezone-logs --query id -o tsv 2>/dev/null)
  if [ -z "$DCE_ID" ]; then
    DCE_ID=$(az monitor data-collection endpoint create \
      -g "$RG" -n firezone-logs -l "$LOCATION" \
      --public-network-access Enabled --query id -o tsv)
  fi

  cat > firezone-dcr.json <<EOF
  {
    "location": "$LOCATION",
    "properties": {
      "dataCollectionEndpointId": "$DCE_ID",
      "streamDeclarations": {
        "Custom-FirezoneLogs_CL": {
          "columns": [
            { "name": "TimeGenerated", "type": "datetime" },
            { "name": "Message", "type": "string" },
            { "name": "Stream", "type": "string" },
            { "name": "Firezone", "type": "dynamic" }
          ]
        }
      },
      "destinations": {
        "logAnalytics": [
          { "workspaceResourceId": "$WORKSPACE_ID", "name": "firezone" }
        ]
      },
      "dataFlows": [
        {
          "streams": ["Custom-FirezoneLogs_CL"],
          "destinations": ["firezone"],
          "transformKql": "source",
          "outputStream": "Custom-FirezoneLogs_CL"
        }
      ]
    }
  }
  EOF

  DCR_ID=$(az monitor data-collection rule show \
    -g "$RG" -n firezone-logs --query id -o tsv 2>/dev/null)
  if [ -z "$DCR_ID" ]; then
    DCR_ID=$(az monitor data-collection rule create \
      -g "$RG" -n firezone-logs --rule-file firezone-dcr.json --query id -o tsv)
  fi

  SP_ID=$(az ad sp show --id FIREZONE_CLIENT_ID --query id -o tsv)

  if ! az role assignment list --assignee "$SP_ID" --scope "$DCR_ID" \
       --role "Monitoring Metrics Publisher" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    az role assignment create --assignee-object-id "$SP_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "Monitoring Metrics Publisher" --scope "$DCR_ID" \
      --output none
  fi

  echo "Enter these in the Firezone form:"
  echo "  Ingestion Endpoint: $(az monitor data-collection endpoint show \
    -g "$RG" -n firezone-logs --query logsIngestion.endpoint -o tsv)"
  echo "  DCR Immutable ID:   $(az monitor data-collection rule show \
    -g "$RG" -n firezone-logs --query immutableId -o tsv)"
  echo "  Stream Name:        Custom-FirezoneLogs_CL"
  """

  @sentinel_terraform_snippet ~S"""
  locals {
    resource_group = "my-resource-group"
    workspace_name = "my-workspace"
    location       = "eastus"
  }

  data "azurerm_log_analytics_workspace" "this" {
    name                = local.workspace_name
    resource_group_name = local.resource_group
  }

  resource "azurerm_monitor_data_collection_endpoint" "firezone" {
    name                = "firezone-logs"
    resource_group_name = local.resource_group
    location            = local.location
  }

  resource "azapi_resource" "firezone_table" {
    type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
    name      = "FirezoneLogs_CL"
    parent_id = data.azurerm_log_analytics_workspace.this.id

    body = jsonencode({
      properties = {
        schema = {
          name = "FirezoneLogs_CL"
          columns = [
            { name = "TimeGenerated", type = "datetime" },
            { name = "Message", type = "string" },
            { name = "Stream", type = "string" },
            { name = "Firezone", type = "dynamic" }
          ]
        }
      }
    })
  }

  resource "azurerm_monitor_data_collection_rule" "firezone" {
    name                        = "firezone-logs"
    resource_group_name         = local.resource_group
    location                    = local.location
    data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.firezone.id

    destinations {
      log_analytics {
        workspace_resource_id = data.azurerm_log_analytics_workspace.this.id
        name                  = "firezone"
      }
    }

    data_flow {
      streams       = ["Custom-FirezoneLogs_CL"]
      destinations  = ["firezone"]
      transform_kql = "source"
      output_stream = "Custom-FirezoneLogs_CL"
    }

    stream_declaration {
      stream_name = "Custom-FirezoneLogs_CL"

      column {
        name = "TimeGenerated"
        type = "datetime"
      }

      column {
        name = "Message"
        type = "string"
      }

      column {
        name = "Stream"
        type = "string"
      }

      column {
        name = "Firezone"
        type = "dynamic"
      }
    }

    depends_on = [azapi_resource.firezone_table]
  }

  data "azuread_service_principal" "firezone" {
    client_id = "FIREZONE_CLIENT_ID"
  }

  resource "azurerm_role_assignment" "firezone_ingest" {
    scope                = azurerm_monitor_data_collection_rule.firezone.id
    role_definition_name = "Monitoring Metrics Publisher"
    principal_id         = data.azuread_service_principal.firezone.object_id
  }

  output "ingestion_endpoint" {
    value = azurerm_monitor_data_collection_endpoint.firezone.logs_ingestion_endpoint
  }

  output "dcr_immutable_id" {
    value = azurerm_monitor_data_collection_rule.firezone.immutable_id
  }
  """

  defp sentinel_cli_snippet do
    String.replace(@sentinel_cli_snippet, "FIREZONE_CLIENT_ID", sentinel_client_id())
  end

  defp sentinel_terraform_snippet do
    String.replace(@sentinel_terraform_snippet, "FIREZONE_CLIENT_ID", sentinel_client_id())
  end

  defp new_sink(S3.LogSink), do: %S3.LogSink{external_id: Ecto.UUID.generate()}
  defp new_sink(schema), do: struct(schema)

  defp trust_policy_json(form) do
    external_id = get_field(form.source, :external_id)
    aws_account_id = S3.APIClient.aws_account_id()

    """
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "AWS": "arn:aws:iam::#{aws_account_id}:root" },
          "Action": "sts:AssumeRole",
          "Condition": { "StringEquals": { "sts:ExternalId": "#{external_id}" } }
        }
      ]
    }\
    """
  end

  defp s3_permission_policy_json(form) do
    bucket =
      case get_field(form.source, :bucket) do
        bucket when is_binary(bucket) and bucket != "" -> bucket
        _ -> "my-firezone-logs"
      end

    resource =
      "arn:aws:s3:::#{bucket}/#{s3_objects_pattern(get_field(form.source, :key_prefix))}"

    """
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": "s3:PutObject",
          "Resource": "#{resource}"
        }
      ]
    }\
    """
  end

  defp s3_objects_pattern(prefix) when is_binary(prefix) do
    case prefix |> String.trim() |> String.trim("/") do
      "" -> "*"
      prefix -> "#{prefix}/*"
    end
  end

  defp s3_objects_pattern(_prefix), do: "*"

  @s3_cli_snippet ~S"""
  BUCKET="SINK_BUCKET"
  REGION="us-east-1"
  ROLE="firezone-logs"

  if ! aws s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    if [ "$REGION" = "us-east-1" ]; then
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" > /dev/null
    else
      aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
        --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
    fi
  fi

  cat > firezone-trust.json <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "AWS": "arn:aws:iam::FIREZONE_AWS_ACCOUNT_ID:root" },
        "Action": "sts:AssumeRole",
        "Condition": { "StringEquals": { "sts:ExternalId": "SINK_EXTERNAL_ID" } }
      }
    ]
  }
  EOF

  if aws iam get-role --role-name "$ROLE" > /dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$ROLE" \
      --policy-document file://firezone-trust.json
  else
    aws iam create-role --role-name "$ROLE" \
      --assume-role-policy-document file://firezone-trust.json > /dev/null
  fi

  aws iam put-role-policy --role-name "$ROLE" --policy-name put-objects \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::$BUCKET/SINK_OBJECTS_PATTERN\"}]}"

  echo "Enter these in the Firezone form:"
  echo "  Bucket:   $BUCKET"
  echo "  Region:   $REGION"
  echo "  Role ARN: $(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
  """

  @s3_terraform_snippet ~S"""
  locals {
    bucket = "SINK_BUCKET"
  }

  resource "aws_s3_bucket" "firezone_logs" {
    bucket = local.bucket
  }

  resource "aws_iam_role" "firezone_logs" {
    name = "firezone-logs"

    assume_role_policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect    = "Allow"
          Principal = { AWS = "arn:aws:iam::FIREZONE_AWS_ACCOUNT_ID:root" }
          Action    = "sts:AssumeRole"
          Condition = { StringEquals = { "sts:ExternalId" = "SINK_EXTERNAL_ID" } }
        }
      ]
    })
  }

  resource "aws_iam_role_policy" "firezone_logs_put" {
    name = "put-objects"
    role = aws_iam_role.firezone_logs.id

    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${aws_s3_bucket.firezone_logs.arn}/SINK_OBJECTS_PATTERN"
        }
      ]
    })
  }

  output "role_arn" {
    value = aws_iam_role.firezone_logs.arn
  }
  """

  defp s3_cli_snippet(form) do
    prefill_s3_snippet(@s3_cli_snippet, form)
  end

  defp s3_terraform_snippet(form) do
    prefill_s3_snippet(@s3_terraform_snippet, form)
  end

  defp prefill_s3_snippet(snippet, form) do
    bucket =
      case get_field(form.source, :bucket) do
        bucket when is_binary(bucket) and bucket != "" -> bucket
        _ -> "my-firezone-logs"
      end

    snippet
    |> String.replace("FIREZONE_AWS_ACCOUNT_ID", S3.APIClient.aws_account_id())
    |> String.replace("SINK_EXTERNAL_ID", get_field(form.source, :external_id) || "")
    |> String.replace("SINK_BUCKET", bucket)
    |> String.replace("SINK_OBJECTS_PATTERN", s3_objects_pattern(get_field(form.source, :key_prefix)))
  end

  defp delivered_count(sink) do
    case sink.delivery_stats do
      %{delivered: delivered} when is_integer(delivered) -> delivered
      _ -> 0
    end
  end

  defp backfill_status(sink) do
    stats = sink.delivery_stats

    cond do
      not sink.retroactive or is_nil(stats) or is_nil(stats.backfill_total) ->
        "—"

      stats.pending_backfills == 0 or stats.backfill_total == 0 ->
        "Done"

      true ->
        "#{min(100, round(stats.backfill_delivered * 100 / stats.backfill_total))}%"
    end
  end

  defp last_delivery_at(sink) do
    case sink.delivery_stats do
      %{last_synced_at: %DateTime{} = at} -> at
      _ -> nil
    end
  end

  defp init(socket, opts \\ []) do
    new = Keyword.get(opts, :new, false)
    repo = Keyword.get(opts, :repo, :replica)
    log_sinks = Database.list_all_sinks(socket.assigns.subject, repo)

    if new do
      socket
      |> assign_new(:log_sinks, fn -> log_sinks end)
      |> assign_new(:open_sink_actions_id, fn -> nil end)
    else
      assign(socket, log_sinks: log_sinks, open_sink_actions_id: nil)
    end
  end

  defmodule Database do
    import Ecto.Query

    alias Portal.Datadog
    alias Portal.Elastic
    alias Portal.NewRelic
    alias Portal.S3
    alias Portal.Safe
    alias Portal.Sentinel
    alias Portal.Splunk

    def list_all_sinks(subject, repo \\ :replica) do
      [
        Splunk.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        Datadog.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        NewRelic.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        Elastic.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        Sentinel.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        S3.LogSink |> Safe.scoped(subject, repo) |> Safe.all()
      ]
      |> List.flatten()
      |> Enum.sort_by(& &1.name)
      |> enrich_with_delivery_stats(subject, repo)
    end

    def get_sink!(schema, id, subject) do
      from(s in schema, where: s.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one!(fallback_to_primary: true)
    end

    def insert_sink(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_sink(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_sink(sink, subject) do
      # Delete the parent Portal.LogSink; the provider row and cursors CASCADE.
      parent =
        from(ls in Portal.LogSink, where: ls.id == ^sink.id)
        |> Safe.scoped(subject, :replica)
        |> Safe.one!(fallback_to_primary: true)

      parent |> Safe.scoped(subject) |> Safe.delete()
    end

    defp enrich_with_delivery_stats(sinks, subject, repo) do
      stats =
        from(c in Portal.LogSinkCursor,
          group_by: c.log_sink_id,
          select: {c.log_sink_id,
           %{
             delivered: type(sum(c.synced_count), :integer),
             last_synced_at: max(c.last_synced_at),
             backfill_total: type(filter(sum(c.backfill_total), c.phase == :backfill), :integer),
             backfill_delivered:
               type(filter(sum(c.synced_count), c.phase == :backfill), :integer),
             pending_backfills: filter(count(), c.phase == :backfill and is_nil(c.completed_at))
           }}
        )
        |> Safe.scoped(subject, repo)
        |> Safe.all()
        |> Map.new()

      Enum.map(sinks, fn sink ->
        Map.put(sink, :delivery_stats, Map.get(stats, sink.id))
      end)
    end
  end
end
