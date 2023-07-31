defmodule Web.FormComponents do
  @moduledoc """
  Provides Form UI components.
  """
  use Phoenix.Component
  use Web, :verified_routes
  import Web.CoreComponents, only: [icon: 1, error: 1, label: 1, translate_error: 1]

  ### Inputs ###

  @doc """
  Renders an input with label and error messages.

  A `%Phoenix.HTML.Form{}` and field name may be passed to the input
  to build input names and error messages, or all the attributes and
  errors may be passed explicitly.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range radio search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox and radio inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(autocomplete cols disabled form list max maxlength min minlength
                pattern placeholder readonly required rows size step)

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(field.errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "radio"} = assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label class="flex items-center gap-2 text-gray-900 dark:text-gray-300">
        <input type="radio" id={@id} name={@name} value={@value} checked={@checked} class={~w[
          w-4 h-4 border-gray-300 focus:ring-2 focus:ring-primary-300
          dark:focus:ring-primary-600 dark:focus:bg-primary-600
          dark:bg-gray-700 dark:border-gray-600]} {@rest} />
        <%= @label %>
      </label>
    </div>
    """
  end

  def input(%{type: "checkbox", value: value} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn -> Phoenix.HTML.Form.normalize_value("checkbox", value) end)

    ~H"""
    <div phx-feedback-for={@name}>
      <label class="flex items-center gap-4 text-sm leading-6 text-zinc-600">
        <input type="hidden" name={@name} value="false" />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="rounded border-zinc-300 text-zinc-900 focus:ring-0"
          {@rest}
        />
        <%= @label %>
      </label>
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <select id={@id} name={@name} class={~w[
          bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500
          focus:border-blue-500 block w-full p-2.5 dark:bg-gray-700 dark:border-gray-600
          dark:placeholder-gray-400 dark:text-white dark:focus:ring-blue-500 dark:focus:border-blue-500
        ]} multiple={@multiple} {@rest}>
        <option :if={@prompt} value=""><%= @prompt %></option>
        <%= Phoenix.HTML.Form.options_for_select(@options, @value) %>
      </select>
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6",
          "phx-no-feedback:border-zinc-300 phx-no-feedback:focus:border-zinc-400",
          "min-h-[6rem] border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "bg-gray-50 p-2.5 block w-full rounded-lg border text-gray-900 focus:ring-primary-600 text-sm",
          "phx-no-feedback:border-gray-300 phx-no-feedback:focus:border-primary-600",
          "disabled:bg-slate-50 disabled:text-slate-500 disabled:border-slate-200 disabled:shadow-none",
          "border-gray-300 focus:border-primary-600",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  attr :name, :any
  attr :value, :any
  attr :checked, :boolean
  attr :rest, :global

  def checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      class="rounded text-blue-600 border-zinc-300 focus:ring-0"
      name={@name}
      value={@value}
      checked={@checked}
      {@rest}
    />
    """
  end

  ### Buttons ###

  @doc """
  Render a button group.
  """
  slot :first, required: true, doc: "First button"
  slot :middle, required: false, doc: "Middle button(s)"
  slot :last, required: true, doc: "Last button"

  def button_group(assigns) do
    ~H"""
    <div class="inline-flex rounded-md shadow-sm" role="group">
      <button type="button" class={~w[
          px-4 py-2 text-sm font-medium text-gray-900 bg-white border border-gray-200
          rounded-l-lg hover:bg-gray-100 hover:text-blue-700 focus:z-10 focus:ring-2
          focus:ring-blue-700 focus:text-blue-700 dark:bg-gray-700 dark:border-gray-600
          dark:text-white dark:hover:text-white dark:hover:bg-gray-600
          dark:focus:ring-blue-500 dark:focus:text-white
        ]}>
        <%= render_slot(@first) %>
      </button>
      <%= for middle <- @middle do %>
        <button type="button" class={~w[
            px-4 py-2 text-sm font-medium text-gray-900 bg-white border-t border-b
            border-gray-200 hover:bg-gray-100 hover:text-blue-700 focus:z-10 focus:ring-2
            focus:ring-blue-700 focus:text-blue-700 dark:bg-gray-700 dark:border-gray-600
            dark:text-white dark:hover:text-white dark:hover:bg-gray-600 dark:focus:ring-blue-500
            dark:focus:text-white
          ]}>
          <%= render_slot(middle) %>
        </button>
      <% end %>
      <button type="button" class={~w[
          px-4 py-2 text-sm font-medium text-gray-900 bg-white border border-gray-200
          rounded-r-lg hover:bg-gray-100 hover:text-blue-700 focus:z-10 focus:ring-2
          focus:ring-blue-700 focus:text-blue-700 dark:bg-gray-700 dark:border-gray-600
          dark:text-white dark:hover:text-white dark:hover:bg-gray-600 dark:focus:ring-blue-500
          dark:focus:text-white
        ]}>
        <%= render_slot(@last) %>
      </button>
    </div>
    """
  end

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value navigate)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75",
        "text-white bg-primary-600 font-medium rounded-lg text-sm px-5 py-2.5 text-center",
        "hover:bg-primary-700",
        "focus:ring-4 focus:outline-none focus:ring-primary-300",
        "dark:bg-primary-600 dark:hover:bg-primary-700 dark:focus:ring-primary-800",
        "active:text-white/80",
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Render a submit button.

  ## Examples

    <.submit_button>
      Save
    </.submit_button>
  """

  slot :inner_block, required: true

  def submit_button(assigns) do
    ~H"""
    <button type="submit" class={~w[
        inline-flex items-center px-5 py-2.5 mt-4 sm:mt-6 text-sm font-medium text-center text-white
        bg-primary-700 rounded-lg focus:ring-4 focus:ring-primary-200 dark:focus:ring-primary-900
        hover:bg-primary-800
      ]}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Render a delete button.

  ## Examples

    <.delete_button path={Routes.user_path(@conn, :edit, @user.id)}/>
      Edit user
    </.delete_button>
  """
  slot :inner_block, required: true
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  def delete_button(assigns) do
    ~H"""
    <button
      type="button"
      class="text-red-600 inline-flex items-center hover:text-white border border-red-600 hover:bg-red-600 focus:ring-4 focus:outline-none focus:ring-red-300 font-medium rounded-lg text-sm px-5 py-2.5 text-center dark:border-red-500 dark:text-red-500 dark:hover:text-white dark:hover:bg-red-600 dark:focus:ring-red-900"
      {@rest}
    >
      <!-- XXX: Fix icon for dark mode -->
      <!-- <.icon name="hero-trash-solid" class="text-red-600 w-5 h-5 mr-1 -ml-1" /> -->
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  @doc """
  Renders an add button.

  ## Examples

    <.add_button navigate={~p"/actors/new"}>
      Add user
    </.add_button>
  """
  attr :navigate, :any, required: true, doc: "Path to navigate to"
  slot :inner_block, required: true

  def add_button(assigns) do
    ~H"""
    <.link navigate={@navigate} class={~w[
        flex items-center justify-center text-white bg-primary-500 hover:bg-primary-600
        focus:ring-4 focus:ring-primary-300 font-medium rounded-lg text-sm px-4 py-2
        dark:bg-primary-600 dark:hover:bg-primary-700 focus:outline-none dark:focus:ring-primary-800
      ]}>
      <.icon name="hero-plus" class="h-3.5 w-3.5 mr-2" />
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  @doc """
  Renders an edit button.

  ## Examples

    <.edit_button path={Routes.user_path(@conn, :edit, @user.id)}/>
      Edit user
    </.edit_button>
  """
  attr :navigate, :any, required: true, doc: "Path to navigate to"
  slot :inner_block, required: true

  def edit_button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="flex items-center justify-center text-white bg-primary-700 hover:bg-primary-800 focus:ring-4 focus:ring-primary-300 font-medium rounded-lg text-sm px-4 py-2 dark:bg-primary-600 dark:hover:bg-primary-700 focus:outline-none dark:focus:ring-primary-800"
    >
      <.icon name="hero-pencil-solid" class="h-3.5 w-3.5 mr-2" />
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  ### Forms ###

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the datastructure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-8 bg-white">
        <%= render_slot(@inner_block, f) %>
        <div :for={action <- @actions} class="mt-2 flex items-center justify-between gap-6">
          <%= render_slot(action, f) %>
        </div>
      </div>
    </.form>
    """
  end
end
