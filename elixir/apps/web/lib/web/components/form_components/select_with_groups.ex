defmodule Web.Components.FormComponents.SelectWithGroups do
  @moduledoc """
  This components allows selecting options from a grouped list with a search.

  It uses callbacks to load the search results dynamically, which allows to
  support large lists of options without loading them all at once.
  """
  use Phoenix.LiveComponent
  import Web.CoreComponents
  alias Phoenix.LiveView.JS

  @impl true
  def mount(socket) do
    socket =
      socket
      |> assign(:search_query, nil)

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_load_options(assigns)
      |> maybe_load_and_dispatch_selected_option(assigns)

    {:ok, socket}
  end

  defp maybe_load_options(socket, %{disabled: true}) do
    socket
    |> assign(:options, [])
    |> assign(:metadata, %Domain.Repo.Paginator.Metadata{})
  end

  defp maybe_load_options(socket, %{list_options_callback: callback}) do
    {:ok, options, metadata} = callback.(nil)

    socket
    |> assign(:options, options)
    |> assign(:metadata, metadata)
  end

  defp maybe_load_and_dispatch_selected_option(socket, assigns) do
    value = assigns.value || assigns.field.value

    name =
      if value not in [nil, ""] do
        {:ok, {_value, name, _slot_assigns} = option} =
          assigns.fetch_option_callback.(value)

        _ = maybe_execute_on_change_callback(socket, option)

        name
      end

    assign(socket, :value_name, name)
  end

  defp maybe_execute_on_change_callback(socket, option) do
    if on_change = Map.get(socket.assigns, :on_change) do
      on_change.(option)
    end
  end

  attr :label, :string, default: nil, doc: "the label for input"
  attr :placeholder, :string, default: nil, doc: "the placeholder for input"

  attr :disabled, :boolean, default: false, doc: "disable the input but still submit it's value"
  attr :required, :boolean, default: false, doc: "mark the input as required"
  attr :autocomplete, :boolean, default: true, doc: "enable autocomplete for the input"

  attr :field, Phoenix.HTML.FormField, doc: "a form field struct retrieved from the form"

  attr :fetch_option_callback, :any,
    required: true,
    doc: """
    a callback that receives a key and returns an option in the format: {:ok, {label, value}}
    """

  attr :list_options_callback, :any,
    required: true,
    doc: """
    a callback that receives a search query (or `nil`) and returns a list of options
    using the `Domain.Repo.list/3` function, eg returning: {:ok, options, metadata},
    where options is a list of options and metadata is a map with pagination info.

    The list of options should be in format of [{group, [{value, key, slot_assigns}, ..]}, ..].

    Where:
    - `id` is the value that will be submitted when the option is selected;
    - `key` is the text that will be shown in the input when the option is selected;
    - `slot_assigns` is a term with additional data that will be passed to the `option` slot.
    """

  attr :id, :any,
    default: nil,
    doc: "the id for the input, will be taken from the form field if `field` is set"

  attr :name, :any,
    doc: "the name for the input, will be taken from the form field if `field` is set"

  attr :value, :any,
    doc: "the value for the input, will be taken from the form field if `field` is set"

  attr :value_name, :string,
    doc: "the text value selected option, will be loaded using `fetch_option_callback` if not set"

  attr :errors, :list,
    doc: "a list of errors for the field, will be taken from form field if `field` is set"

  attr :on_change, :any,
    default: nil,
    doc: "a callback that receives the selected option when it changes"

  slot :options_group, doc: "the content to render for the options group header"
  slot :option, doc: "the content to render for each option"
  slot :no_options, doc: "the content to render when no options are available"
  slot :no_search_results, doc: "the content to render when no search results are available"

  @impl true
  def render(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(:id, assigns.id || field.id)
    |> assign(:field, nil)
    |> assign_new(:errors, fn ->
      if Phoenix.Component.used_input?(field),
        do: Enum.map(field.errors, &translate_error(&1)),
        else: []
    end)
    |> assign_new(:name, fn ->
      field.name
    end)
    |> assign_new(:value, fn ->
      field.value
    end)
    |> render()
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-click-away={
        JS.add_class("hidden", to: "#select-#{@id}-dropdown")
        |> JS.set_attribute({"aria-expanded", "false"}, to: "##{@id}-input")
      }
    >
      <.label :if={@label} for={"#{@id}-input"}>{@label}</.label>

      <div class="relative group">
        <input type="text" name={@name} value={@value} class="hidden" />

        <input
          id={"#{@id}-input"}
          type="text"
          name={@name <> "_name"}
          aria-expanded="false"
          placeholder={@placeholder}
          disabled={@disabled}
          required={@required}
          readonly={true}
          autocomplete={false}
          class={[
            input_class(),
            (@disabled && "cursor-not-allowed") || "cursor-pointer",
            @errors != [] && input_has_errors_class()
          ]}
          value={@value_name}
          phx-click={
            JS.toggle_class("hidden",
              to: "#select-#{@id}-dropdown"
            )
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
            |> JS.focus(to: "#select-" <> @id <> "-search-input")
          }
        />

        <div
          class={[
            "absolute top-1/2 end-2 -translate-y-1/2",
            (@disabled && "cursor-not-allowed") || "cursor-pointer"
          ]}
          phx-click={
            unless @disabled do
              JS.toggle_class("hidden",
                to: "#select-#{@id}-dropdown"
              )
              |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "##{@id}-input")
              |> JS.focus(to: "#select-" <> @id <> "-search-input")
            end
          }
        >
          <.icon name="hero-chevron-up-down" class="w-5 h-5" />
        </div>

        <div
          id={"select-#{@id}-dropdown"}
          class={[
            "hidden",
            "absolute",
            "mt-2 pb-1 px-1 space-y-0.5 z-20",
            "w-full bg-white",
            input_border_class(),
            "border border-gray-200 rounded shadow",
            "overflow-hidden"
          ]}
          role="listbox"
          tabindex="-1"
          aria-orientation="vertical"
        >
          <div class={[
            "max-h-72",
            "overflow-y-auto overflow-x-hidden"
          ]}>
            <div class="bg-white p-2 sticky top-1 z-40">
              <input
                name={"search_query-#{@id}"}
                id={"select-" <> @id <> "-search-input"}
                type="text"
                placeholder="Search"
                autocomplete={false}
                class={[
                  input_class()
                ]}
                value={@search_query}
                phx-change="search"
                phx-debounce="300"
                phx-target={@myself}
              />
            </div>

            <div>
              <div class={[
                "hidden only:block",
                "py-2 px-2",
                "text-sm text-neutral-400"
              ]}>
                <%= if @no_search_results == [] do %>
                  Nothing has been found.
                <% else %>
                  {render_slot(@no_search_results, @search_query)}
                <% end %>
              </div>
              <div
                :for={{group, group_options} <- @options}
                class={[
                  "py-2 px-4",
                  "w-full",
                  "text-sm text-neutral-400"
                ]}
              >
                <div>
                  {render_slot(@options_group, group)}
                </div>
                <div :for={{value, _name, slot_assigns} <- group_options}>
                  <label
                    for={"#{@name}[#{value}]"}
                    tabindex="1"
                    role="option"
                    class={[
                      "block",
                      "w-full py-2 px-4",
                      "text-sm text-neutral-800",
                      "rounded",
                      "hover:bg-neutral-100",
                      "focus:outline-none focus:bg-neutral-100",
                      value != @value && "cursor-pointer",
                      value == @value && "bg-neutral-200 focus:bg-neutral-200 hover:bg-neutral-200"
                    ]}
                  >
                    <input
                      type="radio"
                      name={@name}
                      id={"#{@name}[#{value}]"}
                      value={value}
                      checked={value == @value}
                      class="hidden"
                    />
                    <div
                      phx-click={
                        JS.toggle_class("hidden",
                          to: "#select-#{@id}-dropdown"
                        )
                        |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                        |> JS.focus(to: "#select-" <> @id <> "-search-input")
                      }
                      class={["flex items-center"]}
                    >
                      <div class={["text-gray-800"]}>
                        {render_slot(@option, slot_assigns)}
                      </div>
                      <div :if={value == @value} class="ml-auto">
                        <.icon name="hero-check" class="w-4 h-4" />
                      </div>
                    </div>
                  </label>
                </div>
              </div>
            </div>

            <div
              :if={Map.get(@metadata, :next_page_cursor)}
              class={[
                "py-2 px-4 text-sm text-neutral-400"
              ]}
            >
              <span class="font-semibold">{@metadata.count - @metadata.limit}</span>
              more options available. Use the search to refine the list.
            </div>
          </div>
        </div>
      </div>

      <.error :for={message <- @errors} data-validation-error-for={@name <> "_name"}>
        {message}
      </.error>

      <%= if @options == [] and is_nil(@value) and @no_options != [] and @search_query in [nil, ""] do %>
        {render_slot(@no_options, @name <> "_name")}
      <% end %>
    </div>
    """
  end

  def input_class,
    do: [
      "block p-2 w-full",
      "text-sm bg-neutral-50",
      "text-neutral-900 disabled:text-neutral-400",
      input_border_class()
    ]

  def input_border_class,
    do: [
      "border border-neutral-300 rounded"
    ]

  def input_has_errors_class,
    do: [
      "border border-rose-400 focus:border-rose-400"
    ]

  @impl true
  def handle_event("search", %{"_target" => target} = params, socket) do
    value = get_in(params, target)
    {:ok, options, metadata} = socket.assigns.list_options_callback.(value)

    socket =
      socket
      |> assign(:search_query, value)
      |> assign(:options, options)
      |> assign(:metadata, metadata)

    {:noreply, socket}
  end
end
