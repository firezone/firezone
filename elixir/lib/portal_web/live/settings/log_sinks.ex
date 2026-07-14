defmodule PortalWeb.Settings.LogSinks do
  use PortalWeb, :live_view

  alias Portal.Datadog
  alias Portal.Splunk
  alias __MODULE__.Database

  import Ecto.Changeset

  require Logger

  @modules %{
    "splunk" => Splunk.LogSink,
    "datadog" => Datadog.LogSink
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
    Datadog.LogSink => @common_fields ++ ~w[site api_key tags]a
  }

  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Log Sinks",
        trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?()
      )

    {:ok, init(socket, new: true)}
  end

  # New Log Sink
  def handle_params(%{"type" => type}, _url, %{assigns: %{live_action: :new}} = socket)
      when type in @types do
    schema = Map.get(@modules, type)
    changeset = changeset(struct(schema), %{})

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
              <.sink_form form={@form} type={@type} live_action={@live_action} />
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
              <.sink_form form={@form} type={@type} live_action={@live_action} />
            </div>
            <div class="shrink-0 flex items-center justify-end gap-2 px-5 py-4 border-t border-border">
              <.button phx-click="close_panel">
                Cancel
              </.button>
              <.button
                form="log-sink-form"
                type="submit"
                style="primary"
                disabled={not @form.source.valid? or Enum.empty?(@form.source.changes)}
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

  defp sink_type(sink) do
    case sink.__struct__ do
      Splunk.LogSink -> "splunk"
      Datadog.LogSink -> "datadog"
    end
  end

  defp sink_destination(%Splunk.LogSink{} = sink) do
    case URI.new(sink.collector_url || "") do
      {:ok, %URI{host: host}} when is_binary(host) -> host
      _ -> sink.collector_url
    end
  end

  defp sink_destination(%Datadog.LogSink{} = sink), do: sink.site

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
    alias Portal.Safe
    alias Portal.Splunk

    def list_all_sinks(subject, repo \\ :replica) do
      [
        Splunk.LogSink |> Safe.scoped(subject, repo) |> Safe.all(),
        Datadog.LogSink |> Safe.scoped(subject, repo) |> Safe.all()
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
