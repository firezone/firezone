defmodule Web.TableComponents do
  @moduledoc """
  Provides Table UI components.
  """
  use Phoenix.Component
  use Web, :verified_routes
  import Web.Gettext
  import Web.CoreComponents
  import Web.FormComponents

  attr :columns, :any, required: true, doc: "col slot taken from parent component"
  attr :actions, :any, required: true, doc: "action slot taken from parent component"
  attr :sortable_fields, :list, default: [], doc: "the list of fields that can be sorted"

  def table_header(assigns) do
    ~H"""
    <thead class="text-xs text-neutral-700 uppercase bg-neutral-50">
      <tr>
        <th :for={col <- @columns} class={["px-4 py-3 font-medium", Map.get(col, :class, "")]}>
          <%= col[:label] %>
          <span :if={col[:field] in @sortable_fields}>
            <% {assoc_name, field_name} = col[:field] %>
            <% current_order =
              if match?({^assoc_name, _, ^field_name}, col[:order_by]),
                do: elem(col[:order_by], 1) %>
            <button
              phx-click="order_by"
              phx-value-order_by={"#{assoc_name}:#{current_order || :asc}:#{field_name}"}
            >
              <.icon
                name={
                  cond do
                    current_order == :asc ->
                      "hero-chevron-up-solid"

                    current_order == :desc ->
                      "hero-chevron-down-solid"

                    true ->
                      "hero-chevron-up-down-solid"
                  end
                }
                class="w-4 h-4 ml-1"
              />
            </button>
          </span>
        </th>
        <th :if={not Enum.empty?(@actions)} class="px-4 py-3">
          <span class="sr-only"><%= gettext("Actions") %></span>
        </th>
      </tr>
    </thead>
    """
  end

  attr :id, :any, default: nil, doc: "the function for generating the row id"
  attr :row, :map, required: true, doc: "the row data"
  attr :click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :columns, :any, required: true, doc: "col slot taken from parent component"
  attr :actions, :list, required: true, doc: "action slot taken from parent component"

  attr :mapper, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  def table_row(assigns) do
    ~H"""
    <tr id={@id} class="border-b">
      <td
        :for={{col, _i} <- Enum.with_index(@columns)}
        phx-click={@click && @click.(@row)}
        class={[
          "px-4 py-3",
          @click && "hover:cursor-pointer"
        ]}
      >
        <%= render_slot(col, @mapper.(@row)) %>
      </td>
      <% # this is a hack which allows to hide empty action dropdowns,
      # because LiveView doesn't allow to do <:slot :let={x} :if={x} />
      show_actions? =
        Enum.any?(@actions, fn action ->
          render = render_slot(action, @mapper.(@row))
          not_empty_render?(render)
        end) %>
      <td
        :if={@actions != [] and show_actions?}
        class="px-4 py-3 flex space-x-1 items-center justify-end"
      >
        <span :for={action <- @actions}>
          <%= render_slot(action, @mapper.(@row)) %>
        </span>
      </td>
    </tr>
    """
  end

  defp not_empty_render?(rendered) do
    rendered.dynamic.(nil)
    |> Enum.any?(fn
      "" -> false
      nil -> false
      _other -> true
    end)
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
        <:empty><div class="text-center">No users found</div></:empty>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :sortable_fields, :list, default: [], doc: "the list of fields that can be sorted"
  attr :filters, :list, required: true, doc: "the query filters enabled for the table"
  attr :filter, :map, required: true, doc: "the filter form for the table"

  attr :metadata, :map,
    required: true,
    doc: "the metadata for the table pagination as returned by Repo.list/3"

  slot :col, required: true do
    attr :label, :string
    attr :field, :any
    attr :order_by, :any
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "the slot for showing a message or content when there are no rows"

  def rich_table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <.resource_filter id={"#{@id}-filters"} form={@filter} filters={@filters} />

      <table class="w-full text-sm text-left text-neutral-500 table-fixed" id={@id}>
        <.table_header columns={@col} actions={@action} sortable_fields={@sortable_fields} />
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
            click={@row_click}
            mapper={@row_item}
          />
        </tbody>
      </table>
      <div :if={Enum.empty?(@rows)} id={"#{@id}-empty"}>
        <%= render_slot(@empty) %>
      </div>

      <.paginator metadata={@metadata} />
    </div>
    """
  end

  def resource_filter(assigns) do
    ~H"""
    <.form id={@id} for={@form} phx-change="filter" phx-debounce="100">
      <div
        :for={filter <- @filters}
        class="flex flex-col md:flex-row items-center justify-between space-y-3 md:space-y-0 md:space-x-4 pb-4"
      >
        <div class="w-full md:w-1/2">
          <.filter form={@form} filter={filter} />
        </div>
      </div>
    </.form>
    """
  end

  def filter(%{filter: %{type: {:string, :websearch}}} = assigns) do
    ~H"""
    <div class={["relative w-full"]} phx-feedback-for={@form[@filter.name].name}>
      <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
        <.icon name="hero-magnifying-glass" class="w-5 h-5 text-neutral-500" />
      </div>

      <input
        type="text"
        name={@form[@filter.name].name}
        id={@form[@filter.name].id}
        value={Phoenix.HTML.Form.normalize_value("text", @form[@filter.name].value)}
        placeholder={"Search by " <> @filter.title}
        class={[
          "bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded",
          "block w-full pl-10 p-2",
          "phx-no-feedback:border-neutral-300",
          "disabled:bg-neutral-50 disabled:text-neutral-500 disabled:border-neutral-200 disabled:shadow-none",
          "focus:outline-none focus:border-1 focus:ring-0",
          "border-neutral-300",
          @form[@filter.name].errors != [] && "border-rose-400"
        ]}
      />
      <.error
        :for={msg <- @form[@filter.name].errors}
        data-validation-error-for={@form[@filter.name].name}
      >
        <%= msg %>
      </.error>
    </div>
    """
  end

  def filter(%{filter: %{type: {:string, :email}}} = assigns) do
    ~H"""
    <div class={["relative w-full"]} phx-feedback-for={@form[@filter.name].name}>
      <div class="absolute inset-y-0 left-0 flex items-center pl-3 pointer-events-none">
        <.icon name="hero-magnifying-glass" class="w-5 h-5 text-neutral-500" />
      </div>

      <input
        type="text"
        name={@form[@filter.name].name}
        id={@form[@filter.name].id}
        value={Phoenix.HTML.Form.normalize_value("text", @form[@filter.name].value)}
        placeholder={"Search by " <> @filter.title}
        class={[
          "bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded",
          "block w-full pl-10 p-2",
          "phx-no-feedback:border-neutral-300",
          "disabled:bg-neutral-50 disabled:text-neutral-500 disabled:border-neutral-200 disabled:shadow-none",
          "focus:outline-none focus:border-1 focus:ring-0",
          "border-neutral-300",
          @form[@filter.name].errors != [] && "border-rose-400"
        ]}
      />
      <.error
        :for={msg <- @form[@filter.name].errors}
        data-validation-error-for={@form[@filter.name].name}
      >
        <%= msg %>
      </.error>
    </div>
    """
  end

  def filter(%{filter: %{type: {:string, :uuid}}} = assigns) do
    ~H"""
    <.input
      type="group_select"
      field={@form[@filter.name]}
      options={[
        {nil, [{"For any " <> @filter.title, nil}]},
        {@filter.title, @filter.values}
      ]}
    />
    """
  end

  # TODO: {:list, {:string, :uuid}}
  # |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)

  def filter(%{filter: %{type: :string, values: values}} = assigns) when length(values) > 0 do
    ~H"""
    <.input
      type="group_select"
      field={@form[@filter.name]}
      options={[
        {nil, [{"For any " <> @filter.title, nil}]},
        {@filter.title, @filter.values}
      ]}
    />
    """
  end

  # def filter(assigns) do
  #   ~H"""
  #   <.button_group>
  #     <:first>
  #       All
  #     </:first>
  #     <:middle>
  #       Online
  #     </:middle>
  #     <:last>
  #       Deleted
  #     </:last>
  #   </.button_group>
  #   """
  # end

  def paginator(assigns) do
    ~H"""
    <nav
      class="flex flex-col md:flex-row justify-between items-start md:items-center space-y-3 md:space-y-0 p-4"
      aria-label="Table navigation"
    >
      <span class="text-sm text-neutral-500">
        Showing
        <span class="font-medium text-neutral-900"><%= min(@metadata.limit, @metadata.count) %></span>
        of <span class="font-medium text-neutral-900"><%= @metadata.count %></span>
      </span>
      <ul class="inline-flex items-stretch -space-x-px">
        <li>
          <button
            disabled={is_nil(@metadata.previous_page_cursor)}
            class={[pagination_button_class(), "rounded-l"]}
            phx-click="paginate"
            phx-value-cursor={@metadata.previous_page_cursor}
          >
            <span class="sr-only">Previous</span>
            <.icon name="hero-chevron-left" class="w-5 h-5" />
          </button>
        </li>
        <li>
          <button
            disabled={is_nil(@metadata.next_page_cursor)}
            class={[pagination_button_class(), "rounded-r"]}
            phx-click="paginate"
            phx-value-cursor={@metadata.next_page_cursor}
          >
            <span class="sr-only">Next</span>
            <.icon name="hero-chevron-right" class="w-5 h-5" />
          </button>
        </li>
      </ul>
    </nav>
    """
  end

  defp pagination_button_class do
    ~w[
      flex items-center justify-center h-full py-1.5 px-3 ml-0 text-neutral-500 bg-white
      border border-neutral-300 hover:bg-neutral-100 hover:text-neutral-700
      disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:bg-neutral-100
    ]
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
        <:empty><div class="text-center">No users found</div></:empty>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sortable, :string
    attr :class, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "the slot for showing a message or content when there are no rows"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-left text-neutral-500" id={@id}>
        <.table_header columns={@col} actions={@action} />
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
            click={@row_click}
            mapper={@row_item}
          />
        </tbody>
      </table>
      <div :if={Enum.empty?(@rows)} id={"#{@id}-empty"}>
        <%= render_slot(@empty) %>
      </div>
    </div>
    """
  end

  @doc ~S"""
  Renders a table with groups and generic styling.

  The component is expecting the rows data to be in the form of a list
  of tuples, where the first element of a given tuple is the group and
  the second element of the tuple is a list of elements under that group

  ## Examples

      <.table_with_groups id="users" rows={@grouped_users}>
        <:col label="user group"></:col>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.table>
  """

  attr :id, :string, required: true
  attr :groups, :list, required: true
  attr :group_id, :any, default: nil, doc: "the function for generating the group id"

  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :group_items, :any,
    required: true,
    doc: "a mapper which is used to get list of rows for a group"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sortable, :string
    attr :class, :string
  end

  slot :group, required: true

  slot :action, doc: "the slot for showing user actions in the last table column"
  slot :empty, doc: "the slot for showing a message or content when there are no rows"

  def table_with_groups(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full text-sm text-left text-neutral-500" id={@id}>
      <.table_header columns={@col} actions={@action} />

      <tbody :for={group <- @groups} data-group-id={@group_id && @group_id.(group)}>
        <tr class="bg-neutral-100">
          <td class="px-4 py-2" colspan={length(@col) + 1}>
            <%= render_slot(@group, group) %>
          </td>
        </tr>

        <.table_row
          :for={row <- @group_items.(group)}
          columns={@col}
          actions={@action}
          row={row}
          id={@row_id && @row_id.(row)}
          click={@row_click}
          mapper={@row_item}
        />
      </tbody>
    </table>
    <div :if={Enum.empty?(@groups)}>
      <%= render_slot(@empty) %>
    </div>
    """
  end

  @doc ~S"""
  Renders a table with 2 columns and generic styling.

  The component will likely be used when displaying the properties of an
  individual resource (e.g. Gateway, Resource, Client, etc...)

  The component renders a table that is meant to be viewed vertically, with
  the first column being the label and the second column being the value.

  This component is intended to be used with the `vertical_table_row` component

  ## Examples

      <.vertical_table>
        <.vertical_table_row>
          <:label>First Name</:label>
          <:value>User First Name Here</:value>
        </.vertical_table_row>
        <.vertical_table_row>
          <:label>Last Name</:label>
          <:value>User Last Name Here</:value>
        </.vertical_table_row>
      </.vertical_table>
  """

  attr :class, :string, default: nil
  attr :rest, :global, include: ~w[id]a

  slot :inner_block

  def vertical_table(assigns) do
    ~H"""
    <table class={["w-full text-sm text-left text-neutral-500", @class]} {@rest}>
      <tbody>
        <%= render_slot(@inner_block) %>
      </tbody>
    </table>
    """
  end

  @doc ~S"""
  Renders a row with 2 columns and generic styling.  The first column will be
  the header and the second column will be the value.

  The component will likely be used when displaying the properties of an
  individual resource (e.g. Gateway, Resource, Client, etc...)

  This component is intended to be used with the `vertical_table` component.

  ## Examples

      <.vertical_table_row>
        <:label>First Name</:label>
        <:value>User First Name Here</:value>
      </.vertical_table_row>
  """

  attr :label_class, :string, default: nil
  attr :value_class, :string, default: nil

  slot :label, doc: "the slot for rendering the label of a row"
  slot :value, doc: "the slot for rendering the value of a row"

  def vertical_table_row(assigns) do
    ~H"""
    <tr>
      <th
        scope="row"
        class={[
          "text-right px-6 py-4 font-medium text-neutral-900 whitespace-nowrap",
          "bg-neutral-50 w-1/5",
          @label_class
        ]}
      >
        <%= render_slot(@label) %>
      </th>
      <td class={["px-6 py-4", @value_class]}>
        <%= render_slot(@value) %>
      </td>
    </tr>
    """
  end

  @doc ~S"""
  This component is meant to be used with the table component.  It renders a
  <.link> component that has a specific style for actions in a table.
  """
  attr :navigate, :string, required: true
  slot :inner_block

  def action_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="block py-2 px-4 hover:bg-neutral-100">
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end
end
