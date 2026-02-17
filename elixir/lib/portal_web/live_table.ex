defmodule PortalWeb.LiveTable do
  @moduledoc """
  This module implements a live table component and it's helper function that are built
  on top of `Portal.Repo.list/3` and allows to render a table with sorting, filtering and pagination.
  """
  use Phoenix.LiveView
  import PortalWeb.TableComponents
  import PortalWeb.CoreComponents
  import PortalWeb.FormComponents

  @doc """
  A drop-in replacement of `PortalWeb.TableComponents.table/1` component that adds sorting, filtering and pagination.
  """
  attr :id, :string, required: true, doc: "the id of the table"
  attr :ordered_by, :any, required: true, doc: "the current order for the table"
  attr :filters, :list, required: true, doc: "the query filters enabled for the table"
  attr :filter, :map, required: true, doc: "the filter form for the table"
  attr :stale, :boolean, default: false, doc: "hint to the UI that the table data is stale"
  attr :class, :string, default: nil, doc: "additional classes for the live_table wrapper div"

  attr :metadata, :map,
    required: true,
    doc: "the metadata for the table pagination as returned by Repo.list/3"

  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_patch, :any, default: nil, doc: "the function for generating patch path for each row"
  attr :row_click, :any, default: nil, doc: "fn(row) -> patch path for row click"
  attr :row_selected, :any, default: nil, doc: "fn(row) -> boolean indicating if row is selected"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :field, :any, doc: "the cursor field that to be used for ordering for this column"
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "the slot for showing a message or content when there are no rows"
  slot :prepend_rows, doc: "rows to prepend before the stream rows (rendered in a separate tbody)"

  slot :notice,
    doc: "the slot for showing a notice in the filter bar (e.g. active filter description)" do
    attr :type, :string, doc: "the type of notice: info, warning, danger"
  end

  def live_table(assigns) do
    ~H"""
    <div class={["flex flex-col", @class]}>
      <.resource_filter
        stale={@stale}
        live_table_id={@id}
        form={@filter}
        filters={@filters}
        notice={@notice}
      />
      <div class="flex-1 overflow-auto flex flex-col">
        <table
          class={["w-full text-sm text-left text-[var(--text-secondary)] table-fixed shrink-0"]}
          id={@id}
        >
          <.table_header table_id={@id} columns={@col} actions={@action} ordered_by={@ordered_by} />
          <tbody :if={@prepend_rows != []}>
            {render_slot(@prepend_rows)}
          </tbody>
          <tbody
            id={"#{@id}-rows"}
            phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          >
            <.table_row
              :for={row <- @rows}
              columns={@col}
              actions={@action}
              row={row}
              id={@row_id && @row_id.(row)}
              patch={@row_patch}
              click={@row_click}
              selected={not is_nil(@row_selected) and @row_selected.(row)}
              mapper={@row_item}
            />
          </tbody>
        </table>
        <div
          :if={Enum.empty?(@rows) and not has_filter?(@filter, @filters)}
          id={"#{@id}-empty"}
          class="flex flex-1 items-center justify-center"
        >
          {render_slot(@empty)}
        </div>
        <div
          :if={Enum.empty?(@rows) and has_filter?(@filter, @filters)}
          id={"#{@id}-empty"}
          class="flex flex-1 items-center justify-center"
        >
          <div class="flex flex-col items-center gap-3 py-16">
            <div class="w-9 h-9 rounded-lg border border-[var(--border)] bg-[var(--surface-raised)] flex items-center justify-center">
              <svg
                class="w-4 h-4 text-[var(--text-tertiary)]"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
              >
                <circle cx="7" cy="7" r="4.5" />
                <path d="M10.5 10.5l3 3" />
              </svg>
            </div>
            <div class="text-center">
              <p class="text-sm font-medium text-[var(--text-primary)]">No results found</p>
              <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
                Try adjusting your search or filters.
              </p>
            </div>
            <button
              phx-click="filter"
              phx-value-table_id={@id}
              phx-value-filter={nil}
              class="flex items-center gap-1.5 px-3 py-1.5 rounded border border-[var(--border)] text-xs font-medium text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-strong)] transition-colors"
            >
              <svg
                class="w-3 h-3"
                viewBox="0 0 12 12"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <path d="M1 2.5h10M3 6h6M5 9.5h2" />
              </svg>
              Clear filters
            </button>
          </div>
        </div>
      </div>
      <.paginator id={@id} metadata={@metadata} rows_count={Enum.count(@rows)} />
    </div>
    """
  end

  defp has_filter?(filter, filters) do
    keys =
      Enum.map(filters, fn filter ->
        to_string(filter.name)
      end)

    Map.take(filter.params, keys) != %{}
  end

  defp datetime_input(assigns) do
    ~H"""
    <div class={["flex items-center"]}>
      <input
        placeholder={"#{@filter.title} Started At"}
        type="date"
        name={"#{@field.name}[#{@from_or_to}][date]"}
        id={"#{@field.id}[#{@from_or_to}][date]"}
        value={normalize_value("date", Map.get(@field.value || %{}, @from_or_to))}
        max={@max}
        min="2023-01-01"
        autocomplete="off"
        class={[
          "bg-[var(--surface-raised)] border border-[var(--border)] text-[var(--text-primary)] text-sm rounded-sm",
          "block w-1/2 mr-1",
          "disabled:opacity-50 disabled:shadow-none",
          "focus:outline-hidden focus:ring-0",
          @field.errors != [] && "border-rose-400"
        ]}
      />
      <input
        type="time"
        step="1"
        placeholder={"#{@filter.title} Started At"}
        name={@field.name <> "[#{@from_or_to}][time]"}
        id={@field.id <> "[#{@from_or_to}][time]"}
        value={normalize_value("time", Map.get(@field.value || %{}, @from_or_to)) || "00:00:00"}
        class={[
          "bg-[var(--surface-raised)] border text-[var(--text-primary)] text-sm rounded-sm",
          "block w-1/2",
          "border-[var(--border)]",
          "disabled:opacity-50 disabled:shadow-none",
          "focus:outline-hidden focus:ring-0",
          @field.errors != [] && "border-rose-400"
        ]}
      />
      <.error :for={msg <- @field.errors} data-validation-error-for={@field.name}>
        {msg}
      </.error>
    </div>
    """
  end

  defp normalize_value("date", %DateTime{} = datetime),
    do: DateTime.to_date(datetime) |> Date.to_iso8601()

  defp normalize_value("time", %DateTime{} = datetime),
    do: DateTime.to_time(datetime) |> Time.to_iso8601()

  defp normalize_value(_, nil),
    do: nil

  defp notice_style("info"), do: "bg-blue-100 text-[var(--text-primary)]"
  defp notice_style("warning"), do: "bg-amber-100 text-[var(--text-primary)]"
  defp notice_style("danger"), do: "bg-rose-100 text-[var(--text-primary)]"
  defp notice_style(_), do: "bg-[var(--surface-raised)] text-[var(--text-primary)]"

  defp resource_filter(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-6 py-3 border-b border-[var(--border)] bg-[var(--surface-raised)] shrink-0">
      <.form
        :if={@filters != []}
        id={"#{@live_table_id}-filters"}
        for={@form}
        phx-change="filter"
        phx-debounce="100"
        data-prevent-enter-submit
        class="flex items-center gap-3 flex-1"
      >
        <.input type="hidden" name="table_id" value={@live_table_id} />
        <.filter
          :for={filter <- @filters}
          live_table_id={@live_table_id}
          form={@form}
          filter={filter}
        />
      </.form>
      <.button
        :if={@stale}
        id={"#{@live_table_id}-reload-btn"}
        type="button"
        style="info"
        title="The table data has changed."
        phx-click="reload"
        phx-value-table_id={@live_table_id}
        class="shrink-0"
      >
        <.icon name="remix-loop-left-line" class="mr-1 w-3.5 h-3.5" /> Reload
      </.button>
      <span
        :for={notice <- @notice}
        class={["text-sm px-3 py-1.5 rounded-sm shrink-0", notice_style(notice[:type])]}
      >
        {render_slot(notice)}
      </span>
    </div>
    """
  end

  defp filter(%{filter: %{type: {:range, :datetime}}} = assigns) do
    ~H"""
    <div class="flex items-center">
      <.datetime_input
        field={@form[@filter.name]}
        filter={@filter}
        from_or_to={:from}
        max={Date.utc_today()}
      />
      <div class="mx-2 text-[var(--text-tertiary)]">to</div>
      <.datetime_input
        field={@form[@filter.name]}
        filter={@filter}
        from_or_to={:to}
        max={Date.utc_today()}
      />
    </div>
    """
  end

  defp filter(%{filter: %{type: {:string, :websearch}}} = assigns) do
    ~H"""
    <div class="relative flex-1 max-w-xs" phx-feedback-for={@form[@filter.name].name}>
      <svg
        class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-[var(--text-tertiary)] pointer-events-none"
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
      >
        <circle cx="7" cy="7" r="4.5" />
        <path d="M10.5 10.5l3 3" stroke-linecap="round" />
      </svg>
      <input
        type="text"
        name={@form[@filter.name].name}
        id={@form[@filter.name].id}
        value={Phoenix.HTML.Form.normalize_value("text", @form[@filter.name].value)}
        placeholder={"Search by " <> @filter.title}
        phx-debounce="300"
        class={[
          "w-full pl-8 pr-3 py-1.5 text-sm rounded border",
          "bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)]",
          "placeholder:text-[var(--text-muted)] outline-none transition-colors",
          "focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30",
          @form[@filter.name].errors != [] && "border-rose-400"
        ]}
      />
      <.error
        :for={msg <- @form[@filter.name].errors}
        data-validation-error-for={@form[@filter.name].name}
      >
        {msg}
      </.error>
    </div>
    """
  end

  defp filter(%{filter: %{type: {:string, :email}}} = assigns) do
    ~H"""
    <div class="relative flex-1 max-w-xs" phx-feedback-for={@form[@filter.name].name}>
      <svg
        class="absolute left-2.5 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-[var(--text-tertiary)] pointer-events-none"
        viewBox="0 0 16 16"
        fill="none"
        stroke="currentColor"
        stroke-width="1.75"
      >
        <circle cx="7" cy="7" r="4.5" />
        <path d="M10.5 10.5l3 3" stroke-linecap="round" />
      </svg>
      <input
        type="text"
        name={@form[@filter.name].name}
        id={@form[@filter.name].id}
        value={Phoenix.HTML.Form.normalize_value("text", @form[@filter.name].value)}
        placeholder={"Search by " <> @filter.title}
        phx-debounce="300"
        class={[
          "w-full pl-8 pr-3 py-1.5 text-sm rounded border",
          "bg-[var(--control-bg)] border-[var(--control-border)] text-[var(--text-primary)]",
          "placeholder:text-[var(--text-muted)] outline-none transition-colors",
          "focus:border-[var(--control-focus)] focus:ring-1 focus:ring-[var(--control-focus)]/30",
          @form[@filter.name].errors != [] && "border-rose-400"
        ]}
      />
      <.error
        :for={msg <- @form[@filter.name].errors}
        data-validation-error-for={@form[@filter.name].name}
      >
        {msg}
      </.error>
    </div>
    """
  end

  defp filter(%{filter: %{type: {:string, :uuid}}} = assigns) do
    ~H"""
    <div class="flex items-center order-4">
      <div class="w-full">
        <.input
          type="group_select"
          field={@form[@filter.name]}
          options={
            [
              {nil, [{"For any " <> @filter.title, nil}]}
            ] ++ @filter.values
          }
        />
      </div>
    </div>
    """
  end

  defp filter(%{filter: %{type: {:string, :select}}} = assigns) do
    ~H"""
    <div class="flex items-center order-4">
      <.input
        type="select"
        field={@form[@filter.name]}
        prompt={"All " <> pluralize(@filter.title)}
        options={@filter.values}
      />
    </div>
    """
  end

  defp filter(%{filter: %{type: :string, values: values}} = assigns)
       when values != [] and length(values) < 5 do
    ~H"""
    <div class="flex items-center gap-1 rounded border border-[var(--border)] bg-[var(--control-bg)] p-0.5 shrink-0">
      <label
        for={"#{@live_table_id}-#{@filter.name}-__all__"}
        class={[
          "px-2.5 py-1 rounded text-xs font-medium transition-colors cursor-pointer",
          if(is_nil(@form[@filter.name].value),
            do: "bg-[var(--surface)] text-[var(--text-primary)] shadow-sm",
            else: "text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
          )
        ]}
      >
        <.input
          id={"#{@live_table_id}-#{@filter.name}-__all__"}
          type="radio"
          field={@form[@filter.name]}
          name={"_reset:" <> @form[@filter.name].name}
          value="true"
          checked={is_nil(@form[@filter.name].value)}
          class="hidden"
        /> All
      </label>
      <label
        :for={{label, value} <- @filter.values}
        for={"#{@live_table_id}-#{@filter.name}-#{value}"}
        class={[
          "px-2.5 py-1 rounded text-xs font-medium transition-colors cursor-pointer",
          if(@form[@filter.name].value == value,
            do: "bg-[var(--surface)] text-[var(--text-primary)] shadow-sm",
            else: "text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
          )
        ]}
      >
        <.input
          id={"#{@live_table_id}-#{@filter.name}-#{value}"}
          type="radio"
          field={@form[@filter.name]}
          value={value}
          checked={@form[@filter.name].value == value}
          class="hidden"
        />
        {label}
      </label>
    </div>
    """
  end

  defp filter(%{filter: %{type: :string, values: values}} = assigns) when values != [] do
    ~H"""
    <div class="flex items-center order-4">
      <div class="w-full">
        <.input
          type="select"
          field={@form[@filter.name]}
          prompt={"For any " <> @filter.title}
          options={@filter.values}
        />
      </div>
    </div>
    """
  end

  def paginator(assigns) do
    ~H"""
    <div
      :if={@rows_count > 0}
      class="shrink-0 flex items-center justify-between px-6 py-2.5 border-t border-[var(--border)] bg-[var(--surface-raised)] text-xs text-[var(--text-tertiary)]"
    >
      <span>
        Showing <span class="font-medium tabular-nums text-[var(--text-primary)]">{@rows_count}</span>
        of <span class="font-medium tabular-nums text-[var(--text-primary)]">{@metadata.count}</span>
      </span>
      <div class="flex items-center gap-4">
        <div class="flex items-center gap-1.5">
          <span>Per page</span>
          <select
            name="limit"
            phx-change="change_limit"
            phx-value-table_id={@id}
            class="py-0.5 pl-2 pr-6 rounded border border-[var(--control-border)] bg-[var(--control-bg)] text-[var(--text-primary)] text-xs outline-none focus:border-[var(--control-focus)] transition-colors cursor-pointer"
          >
            <option value="10" selected={@metadata.limit == 10}>10</option>
            <option value="25" selected={@metadata.limit == 25}>25</option>
            <option value="50" selected={@metadata.limit == 50}>50</option>
          </select>
        </div>
        <div class="flex items-center gap-0.5">
          <button
            disabled={is_nil(@metadata.previous_page_cursor)}
            class={[
              "flex items-center justify-center w-7 h-7 rounded transition-colors",
              "text-[var(--text-secondary)] hover:bg-[var(--surface)] hover:text-[var(--text-primary)]",
              "disabled:text-[var(--text-muted)] disabled:cursor-not-allowed disabled:hover:bg-transparent"
            ]}
            phx-click="paginate"
            phx-value-cursor={@metadata.previous_page_cursor}
            phx-value-table_id={@id}
          >
            <svg
              class="w-3.5 h-3.5"
              viewBox="0 0 14 14"
              fill="none"
              stroke="currentColor"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M9 11L5 7l4-4" />
            </svg>
          </button>
          <button
            disabled={is_nil(@metadata.next_page_cursor)}
            class={[
              "flex items-center justify-center w-7 h-7 rounded transition-colors",
              "text-[var(--text-secondary)] hover:bg-[var(--surface)] hover:text-[var(--text-primary)]",
              "disabled:text-[var(--text-muted)] disabled:cursor-not-allowed disabled:hover:bg-transparent"
            ]}
            phx-click="paginate"
            phx-value-cursor={@metadata.next_page_cursor}
            phx-value-table_id={@id}
          >
            <svg
              class="w-3.5 h-3.5"
              viewBox="0 0 14 14"
              fill="none"
              stroke="currentColor"
              stroke-width="1.75"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M5 3l4 4-4 4" />
            </svg>
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Loads the initial state for a live table and persists it to the socket assigns.
  """
  def assign_live_table(socket, id, opts) do
    query_module = Keyword.fetch!(opts, :query_module)
    sortable_fields = Keyword.fetch!(opts, :sortable_fields)
    callback = Keyword.fetch!(opts, :callback)
    enforce_filters = Keyword.get(opts, :enforce_filters, [])
    hide_filters = Keyword.get(opts, :hide_filters, [])
    limit = Keyword.get(opts, :limit, 10)

    # Note: we don't support nesting, :and or :where on the UI yet
    hidden_filters = Enum.map(enforce_filters, &elem(&1, 0)) ++ hide_filters

    assign(socket,
      live_table_ids: [id] ++ (socket.assigns[:live_table_ids] || []),
      query_module_by_table_id:
        put_table_state(
          socket,
          id,
          :query_module_by_table_id,
          query_module
        ),
      callback_by_table_id:
        put_table_state(
          socket,
          id,
          :callback_by_table_id,
          callback
        ),
      sortable_fields_by_table_id:
        put_table_state(
          socket,
          id,
          :sortable_fields_by_table_id,
          sortable_fields
        ),
      filters_by_table_id:
        put_table_state(
          socket,
          id,
          :filters_by_table_id,
          preload_filters(query_module, hidden_filters, socket.assigns.subject)
        ),
      enforced_filters_by_table_id:
        put_table_state(
          socket,
          id,
          :enforced_filters_by_table_id,
          enforce_filters
        ),
      order_by_table_id:
        put_table_state(
          socket,
          id,
          :order_by_table_id,
          maybe_use_default_order_by(query_module)
        ),
      limit_by_table_id: put_table_state(socket, id, :limit_by_table_id, limit)
    )
  end

  defp preload_filters(query_module, hidden_filters, subject) do
    query_module
    |> Portal.Repo.Query.get_filters()
    |> Enum.reject(fn filter -> is_nil(filter.title) or filter.name in hidden_filters end)
    |> Enum.map(&preload_values(&1, query_module, subject))
  end

  def presence_updates_any_id?(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          payload: %{joins: joins, leaves: leaves}
        },
        rendered_ids
      ) do
    updated_ids = Map.keys(joins) ++ Map.keys(leaves)
    Enum.any?(updated_ids, &(&1 in rendered_ids))
  end

  def reload_live_table!(socket, id) do
    callback = Map.fetch!(socket.assigns.callback_by_table_id, id)
    list_opts = Map.get(socket.assigns[:list_opts_by_table_id] || %{}, id, [])

    socket = assign(socket, stale: false)

    case callback.(socket, list_opts) do
      {:error, _reason} ->
        push_navigate(socket, to: socket.assigns.current_path)

      {:ok, socket} ->
        :ok = maybe_notify_test_pid(id)
        socket
    end
  end

  if Mix.env() == :test do
    defp maybe_notify_test_pid(id) do
      if test_pid = Portal.Config.get_env(:portal, :test_pid) do
        send(test_pid, {:live_table_reloaded, id})
      end

      :ok
    end
  else
    defp maybe_notify_test_pid(_id), do: :ok
  end

  @doc """
  This function should be called on each `c:LiveView.handle_params/3` call to
  re-query the list of items using query parameters and update the socket assigns
  with the new state.
  """
  def handle_live_tables_params(socket, params, _uri) do
    Enum.reduce(socket.assigns.live_table_ids, socket, fn id, socket ->
      handle_live_table_params(socket, params, id)
    end)
  end

  defp handle_live_table_params(socket, params, id) do
    query_module = Map.fetch!(socket.assigns.query_module_by_table_id, id)
    enforced_filters = Map.fetch!(socket.assigns.enforced_filters_by_table_id, id)
    sortable_fields = Map.fetch!(socket.assigns.sortable_fields_by_table_id, id)
    limit = Map.fetch!(socket.assigns.limit_by_table_id, id)

    with {:ok, filter} <- params_to_filter(id, params),
         filter = enforced_filters ++ filter,
         {:ok, page} <- params_to_page(id, limit, params),
         {:ok, order_by} <- params_to_order_by(sortable_fields, id, params) do
      list_opts = [
        page: page,
        filter: filter,
        order_by: List.wrap(order_by)
      ]

      case maybe_apply_callback(socket, id, list_opts) do
        {:ok, socket} ->
          socket
          |> assign(
            filter_form_by_table_id:
              put_table_state(
                socket,
                id,
                :filter_form_by_table_id,
                filter_to_form(filter, id)
              ),
            order_by_table_id:
              put_table_state(
                socket,
                id,
                :order_by_table_id,
                maybe_use_default_order_by(query_module, order_by)
              ),
            list_opts_by_table_id:
              put_table_state(
                socket,
                id,
                :list_opts_by_table_id,
                list_opts
              )
          )

        {:error, :invalid_cursor} ->
          message = "The page was reset due to invalid pagination cursor."
          reset_live_table_params(socket, id, message)

        {:error, {:unknown_filter, _metadata}} ->
          message = "The page was reset due to use of undefined pagination filter."
          reset_live_table_params(socket, id, message)

        {:error, {:invalid_type, _metadata}} ->
          message = "The page was reset due to invalid value of a pagination filter."
          reset_live_table_params(socket, id, message)

        {:error, {:invalid_value, _metadata}} ->
          message = "The page was reset due to invalid value of a pagination filter."
          reset_live_table_params(socket, id, message)

        {:error, _reason} ->
          raise PortalWeb.LiveErrors.NotFoundError
      end
    else
      {:error, :invalid_filter} ->
        message = "The page was reset due to invalid pagination filter."
        reset_live_table_params(socket, id, message)
    end
  end

  defp maybe_use_default_order_by(query_module, order_by \\ nil)

  defp maybe_use_default_order_by(query_module, nil) do
    if function_exported?(query_module, :cursor_fields, 0) do
      query_module.cursor_fields() |> List.first()
    else
      []
    end
  end

  defp maybe_use_default_order_by(_query_module, order_by) do
    order_by
  end

  defp reset_live_table_params(socket, id, message) do
    {:noreply, socket} =
      socket
      |> put_flash(:error, message)
      |> update_query_params(fn query_params ->
        Map.reject(query_params, fn {key, _} -> String.starts_with?(key, "#{id}_") end)
      end)

    socket
  end

  defp maybe_apply_callback(socket, id, list_opts) do
    previous_list_opts = Map.get(socket.assigns[:list_opts_by_table_id] || %{}, id, [])

    if list_opts != previous_list_opts do
      callback = Map.fetch!(socket.assigns.callback_by_table_id, id)
      callback.(socket, list_opts)
    else
      {:ok, socket}
    end
  end

  defp put_table_state(socket, id, key, value) do
    Map.put(socket.assigns[key] || %{}, id, value)
  end

  defp preload_values(%{values: fun} = filter, _query_module, subject) when is_function(fun, 1) do
    options = fun.(subject) |> Enum.map(&{&1.name, &1.id})
    %{filter | values: options}
  end

  defp preload_values(filter, _query_module, _subject),
    do: filter

  defp params_to_page(id, limit, params) do
    effective_limit =
      case Map.get(params, "#{id}_limit") do
        val when val in ["10", "25", "50"] -> String.to_integer(val)
        _ -> limit
      end

    if cursor = Map.get(params, "#{id}_cursor") do
      {:ok, [cursor: cursor, limit: effective_limit]}
    else
      {:ok, [limit: effective_limit]}
    end
  end

  defp params_to_filter(id, params) do
    params
    |> Map.get("#{id}_filter", [])
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      case cast_filter(value) do
        {:ok, nil} -> {:cont, acc}
        {:ok, value} -> {:cont, {:ok, [{String.to_existing_atom(key), value}] ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast_filter(%{"from" => from, "to" => to}) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from),
         {:ok, to, 0} <- DateTime.from_iso8601(to) do
      {:ok, %Portal.Repo.Filter.Range{from: from, to: to}}
    else
      _other -> {:error, :invalid_filter}
    end
  end

  defp cast_filter(%{"to" => to}) do
    with {:ok, to, 0} <- DateTime.from_iso8601(to) do
      {:ok, %Portal.Repo.Filter.Range{to: to}}
    else
      _other -> {:error, :invalid_filter}
    end
  end

  defp cast_filter(%{"from" => from}) do
    with {:ok, from, 0} <- DateTime.from_iso8601(from) do
      {:ok, %Portal.Repo.Filter.Range{from: from}}
    else
      _other -> {:error, :invalid_filter}
    end
  end

  defp cast_filter("") do
    {:ok, nil}
  end

  defp cast_filter(binary) when is_binary(binary) do
    {:ok, binary}
  end

  defp cast_filter(_other) do
    {:error, :invalid_filter}
  end

  @doc false
  def filter_to_form(filter, as) do
    # Note: we don't support nesting, :and or :where on the UI yet
    for {key, value} <- filter, into: %{} do
      {Atom.to_string(key), value}
    end
    |> to_form(as: as)
  end

  defp params_to_order_by(sortable_fields, id, params) do
    order_by =
      Map.get(params, "#{id}_order_by", "")
      |> parse_order_by(sortable_fields)

    {:ok, order_by}
  end

  defp parse_order_by(order_by, sortable_fields) do
    with [field_assoc, field_direction, field_field] <- String.split(order_by, ":", parts: 3),
         {assoc, field} <-
           Enum.find(sortable_fields, fn {assoc, field} ->
             to_string(assoc) == field_assoc && to_string(field) == field_field
           end),
         field_direction when field_direction in ["asc", "desc"] <- field_direction do
      {assoc, String.to_existing_atom(field_direction), field}
    else
      _other -> nil
    end
  end

  def handle_live_table_event("table_row_click", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_live_table_event("change_limit", %{"table_id" => id, "limit" => limit}, socket) do
    update_query_params(socket, fn query_params ->
      query_params
      |> delete_cursor_from_params(id)
      |> Map.put("#{id}_limit", limit)
    end)
  end

  def handle_live_table_event("reload", %{"table_id" => id}, socket) do
    {:noreply, reload_live_table!(socket, id)}
  end

  def handle_live_table_event("paginate", %{"table_id" => id, "cursor" => cursor}, socket) do
    update_query_params(socket, fn query_params ->
      put_cursor_to_params(query_params, id, cursor)
    end)
  end

  def handle_live_table_event("order_by", %{"table_id" => id, "order_by" => order_by}, socket) do
    sortable_fields = Map.fetch!(socket.assigns.sortable_fields_by_table_id, id)

    order_by =
      order_by
      |> parse_order_by(sortable_fields)
      |> reverse_order_by()

    update_query_params(socket, fn query_params ->
      query_params
      |> delete_cursor_from_params(id)
      |> put_order_by_to_params(id, order_by)
    end)
  end

  def handle_live_table_event(
        "filter",
        %{"_target" => ["_reset:" <> id, field], "table_id" => id},
        socket
      ) do
    update_query_params(socket, fn query_params ->
      query_params
      |> delete_cursor_from_params(id)
      |> Map.reject(fn {key, _} -> String.starts_with?(key, "#{id}_filter[#{field}]") end)
    end)
  end

  def handle_live_table_event("filter", %{"table_id" => id} = params, socket) do
    filter = Map.get(params, id, %{})

    update_query_params(socket, fn query_params ->
      query_params
      |> delete_cursor_from_params(id)
      |> put_filter_to_params(id, filter)
    end)
  end

  defp reverse_order_by({assoc, :asc, field}), do: {assoc, :desc, field}
  defp reverse_order_by({assoc, :desc, field}), do: {assoc, :asc, field}
  defp reverse_order_by(nil), do: nil

  def update_query_params(socket, update_fun) when is_function(update_fun, 1) do
    query =
      socket.assigns.query_params
      |> update_fun.()
      |> Enum.flat_map(fn
        {key, values} when is_list(values) -> Enum.map(values, &{"#{key}[]", &1})
        {key, values} when is_map(values) -> values |> Map.values() |> Enum.map(&{"#{key}[]", &1})
        {key, value} -> [{key, value}]
      end)
      |> URI.encode_query(:rfc3986)

    path = socket.assigns.current_path
    {:noreply, push_patch(socket, to: String.trim_trailing("#{path}?#{query}", "?"))}
  end

  defp put_cursor_to_params(params, id, cursor) do
    Map.put(params, "#{id}_cursor", cursor)
  end

  defp delete_cursor_from_params(params, id) do
    Map.delete(params, "#{id}_cursor")
  end

  defp put_order_by_to_params(params, id, {assoc, direction, field}) do
    Map.put(params, "#{id}_order_by", "#{assoc}:#{direction}:#{field}")
  end

  defp put_order_by_to_params(params, id, nil) do
    Map.delete(params, "#{id}_order_by")
  end

  defp put_filter_to_params(params, id, filter) do
    filter_params = flatten_filter(filter, "#{id}_filter", %{})

    params
    |> Map.reject(fn {key, _} -> String.starts_with?(key, "#{id}_filter[") end)
    |> Map.merge(filter_params)
  end

  defp flatten_filter([], _key_prefix, acc) do
    acc
  end

  defp flatten_filter(map, key_prefix, acc) when is_map(map) do
    flatten_filter(Map.to_list(map), key_prefix, acc)
  end

  defp flatten_filter([{_key, ""} | rest], key_prefix, acc) do
    flatten_filter(rest, key_prefix, acc)
  end

  defp flatten_filter([{_key, "__all__"} | rest], key_prefix, acc) do
    flatten_filter(rest, key_prefix, acc)
  end

  defp flatten_filter([{key, %{"date" => _} = datetime_range_filter} | rest], key_prefix, acc) do
    if value = normalize_datetime_filter(datetime_range_filter) do
      flatten_filter(rest, key_prefix, Map.put(acc, "#{key_prefix}[#{key}]", value))
    else
      flatten_filter(rest, key_prefix, acc)
    end
  end

  defp flatten_filter([{key, value} | rest], key_prefix, acc)
       when is_list(value) or is_map(value) do
    acc = Map.merge(acc, flatten_filter(value, "#{key_prefix}[#{key}]", %{}))
    flatten_filter(rest, key_prefix, acc)
  end

  defp flatten_filter([{key, value} | rest], key_prefix, acc) do
    flatten_filter(rest, key_prefix, Map.put(acc, "#{key_prefix}[#{key}]", value))
  end

  defp normalize_datetime_filter(params) do
    with {:ok, date} <- Date.from_iso8601(params["date"]),
         {:ok, time} <- normalize_time_filter(params["time"] || "00:00:00") do
      DateTime.new!(date, time) |> DateTime.to_iso8601()
    else
      _other -> nil
    end
  end

  defp normalize_time_filter(time) when byte_size(time) == 5 do
    Time.from_iso8601(time <> ":00")
  end

  defp normalize_time_filter(time) do
    Time.from_iso8601(time)
  end

  defp pluralize(word) do
    cond do
      String.ends_with?(word, "y") -> String.slice(word, 0..-2//1) <> "ies"
      String.ends_with?(word, "s") -> word
      true -> word <> "s"
    end
  end
end
