defmodule Web.TableComponents do
  @moduledoc """
  Provides Table UI components.
  """
  use Phoenix.Component
  use Web, :verified_routes
  import Web.Gettext
  import Web.CoreComponents

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
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
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
        <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
          <tr>
            <th :for={col <- @col} class="px-4 py-3">
              <%= col[:label] %>
              <.icon
                :if={col[:sortable] == "true"}
                name="hero-chevron-up-down-solid"
                class="w-4 h-4 ml-1"
              />
            </th>
            <th class="px-4 py-3">
              <span class="sr-only"><%= gettext("Actions") %></span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="border-b dark:border-gray-700">
            <td
              :for={{col, _i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={[
                "px-4 py-3",
                @row_click && "hover:cursor-pointer"
              ]}
            >
              <%= render_slot(col, @row_item.(row)) %>
            </td>
            <td :if={@action != []} class="px-4 py-3 flex items-center justify-end">
              <button
                id={"#{@row_id.(row)}-dropdown-button"}
                data-dropdown-toggle={"#{@row_id.(row)}-dropdown"}
                class={~w[
                  inline-flex items-center p-0.5 text-sm font-medium text-center
                  text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none
                  dark:text-gray-400 dark:hover:text-gray-100
                ]}
                type="button"
              >
                <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
              </button>
              <div id={"#{@row_id.(row)}-dropdown" } class={~w[
                  hidden z-10 w-44 bg-white rounded divide-y divide-gray-100
                  shadow border border-gray-300 dark:bg-gray-700 dark:divide-gray-600"
                ]}>
                <ul
                  class="py-1 text-sm text-gray-700 dark:text-gray-200"
                  aria-labelledby={"#{@row_id.(row)}-dropdown-button"}
                >
                  <li :for={action <- @action}>
                    <%= render_slot(action, @row_item.(row)) %>
                  </li>
                </ul>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc ~S"""
  Renders a table with groups and generic styling.

  The component is expecting the rows data to be in the form of a list
  of tuples, where the first element of a given tuple is the group and
  the second element of the tuple is a list of elements under that group

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.table>
  """

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sortable, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table_with_groups(assigns) do
    ~H"""
    <table class="w-full text-sm text-left text-gray-500 dark:text-gray-400">
      <thead class="text-xs text-gray-700 uppercase bg-gray-50 dark:bg-gray-700 dark:text-gray-400">
        <tr>
          <th :for={col <- @col} class="px-4 py-3">
            <%= col[:label] %>
            <.icon
              :if={col[:sortable] == "true"}
              name="hero-chevron-up-down-solid"
              class="w-4 h-4 ml-1"
            />
          </th>
          <th class="px-4 py-3">
            <span class="sr-only"><%= gettext("Actions") %></span>
          </th>
        </tr>
      </thead>
      <tbody>
        <%= for {group, items} <- @rows do %>
          <tr class="bg-neutral-300">
            <td class="px-4 py-2">
              <%= group.name_prefix %>
            </td>
            <td colspan={length(@col)}></td>
          </tr>
          <tr :for={item <- items} class="border-b dark:border-gray-700">
            <td :for={col <- @col} class="px-4 py-3">
              <%= render_slot(col, item) %>
            </td>
            <td :if={@action != []} class="px-4 py-3 flex items-center justify-end">
              <button
                id={"#{@row_id.(item)}-dropdown-button"}
                data-dropdown-toggle={"#{@row_id.(item)}-dropdown"}
                class={~w[
                  inline-flex items-center p-0.5 text-sm font-medium text-center
                  text-gray-500 hover:text-gray-800 rounded-lg focus:outline-none
                  dark:text-gray-400 dark:hover:text-gray-100
                ]}
                type="button"
              >
                <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
              </button>
              <div id={"#{@row_id.(item)}-dropdown" } class={~w[
                  hidden z-10 w-44 bg-white rounded divide-y divide-gray-100
                  shadow border border-gray-300 dark:bg-gray-700 dark:divide-gray-600"
                ]}>
                <ul
                  class="py-1 text-sm text-gray-700 dark:text-gray-200"
                  aria-labelledby={"#{@row_id.(item)}-dropdown-button"}
                >
                  <li :for={action <- @action}>
                    <%= render_slot(action, @row_item.(item)) %>
                  </li>
                </ul>
              </div>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end
end
