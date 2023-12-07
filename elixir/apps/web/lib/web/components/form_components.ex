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
  attr :prefix, :string, default: nil
  attr :value, :any

  attr :value_id, :any,
    default: nil,
    doc: "the function for generating the value from the list of schemas for select inputs"

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file hidden month number password
               range radio search select tel text textarea taglist time url week)

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
    |> assign_new(:value, fn ->
      if assigns.value_id do
        Enum.map(field.value, fn
          %Ecto.Changeset{} = value ->
            value
            |> Ecto.Changeset.apply_changes()
            |> assigns.value_id.()

          value ->
            assigns.value_id.(value)
        end)
      else
        field.value
      end
    end)
    |> input()
  end

  def input(%{type: "radio"} = assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label class="flex items-center gap-2 text-neutral-900">
        <input type="radio" id={@id} name={@name} value={@value} checked={@checked} class={~w[
          w-4 h-4 border-neutral-300]} {@rest} />
        <%= @label %>
        <%= if @inner_block, do: render_slot(@inner_block) %>
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
          class={[
            "rounded border-zinc-300 text-zinc-900",
            "checked:bg-accent-500 checked:hover:bg-accent-500"
          ]}
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
          bg-neutral-50 border border-neutral-300 text-neutral-900 text-sm rounded
          block w-full p-2.5]} multiple={@multiple} {@rest}>
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
          "mt-2 block w-full rounded text-zinc-900 sm:text-sm sm:leading-6",
          "phx-no-feedback:border-zinc-300",
          "min-h-[6rem] border-zinc-300",
          @errors != [] && "border-rose-400"
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "taglist"} = assigns) do
    values =
      if is_nil(assigns.value),
        do: [],
        else: Enum.map(assigns.value, &Phoenix.HTML.Form.normalize_value("text", &1))

    assigns = assign(assigns, :values, values)

    ~H"""
    <div phx-feedback-for={@name}>
      <.label for={@id}><%= @label %></.label>

      <div :for={{value, index} <- Enum.with_index(@values)} class="flex mt-2">
        <input
          type="text"
          name={"#{@name}[]"}
          id={@id}
          value={value}
          class={[
            "bg-neutral-50 p-2.5 block w-full rounded border text-neutral-900 text-sm",
            "phx-no-feedback:border-neutral-300",
            "disabled:bg-neutral-50 disabled:text-neutral-500 disabled:border-neutral-200 disabled:shadow-none",
            "border-neutral-300",
            @errors != [] && "border-rose-400"
          ]}
          {@rest}
        />
        <.button
          type="button"
          phx-click={"delete:#{@name}"}
          phx-value-index={index}
          class="align-middle ml-2 inline-block whitespace-nowrap"
        >
          <.icon name="hero-minus" /> Delete
        </.button>
      </div>

      <.button type="button" phx-click={"add:#{@name}"} class="mt-2">
        <.icon name="hero-plus" /> Add
      </.button>

      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      id={@id}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      {@rest}
    />
    """
  end

  def input(%{type: "text", prefix: prefix} = assigns) when not is_nil(prefix) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label :if={not is_nil(@label)} for={@id}><%= @label %></.label>
      <div class={[
        "flex items-center",
        "text-sm text-neutral-900 bg-neutral-50",
        "border-neutral-300 border rounded",
        "w-full",
        "phx-no-feedback:border-neutral-300",
        "focus-within:outline-none focus-within:border-accent-600",
        "peer-disabled:bg-neutral-50 peer-disabled:text-neutral-500 peer-disabled:border-neutral-200 peer-disabled:shadow-none",
        @errors != [] && "border-rose-400"
      ]}>
        <div
          class={[
            "-mr-5",
            "select-none cursor-text",
            "text-neutral-500",
            "p-2.5 block"
          ]}
          id={"#{@id}-prefix"}
          phx-hook="Refocus"
          data-refocus={@id}
        >
          <%= @prefix %>
        </div>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            "text-sm text-neutral-900 bg-transparent border-0",
            "p-2.5 block w-full",
            "focus:outline-none focus:border-0 focus:ring-0"
          ]}
          {@rest}
        />
      </div>
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <.label :if={not is_nil(@label)} for={@id}><%= @label %></.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "bg-neutral-50 p-2.5 block w-full rounded border text-neutral-900 text-sm",
          "phx-no-feedback:border-neutral-300",
          "disabled:bg-neutral-50 disabled:text-neutral-500 disabled:border-neutral-200 disabled:shadow-none",
          "border-neutral-300",
          @errors != [] && "border-rose-400"
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors} data-validation-error-for={@name}><%= msg %></.error>
    </div>
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
          px-4 py-2 text-sm font-medium text-neutral-900 bg-white border border-neutral-200
          rounded-l hover:bg-neutral-100 hover:text-accent-700
        ]}>
        <%= render_slot(@first) %>
      </button>
      <%= for middle <- @middle do %>
        <button type="button" class={~w[
            px-4 py-2 text-sm font-medium text-neutral-900 bg-white border-t border-b
            border-neutral-200 hover:bg-neutral-100 hover:text-accent-700
          ]}>
          <%= render_slot(middle) %>
        </button>
      <% end %>
      <button type="button" class={~w[
          px-4 py-2 text-sm font-medium text-neutral-900 bg-white border border-neutral-200
          rounded-r hover:bg-neutral-100 hover:text-accent-700
        ]}>
        <%= render_slot(@last) %>
      </button>
    </div>
    """
  end

  @doc """
  Base button type to be used directly or by the specialized button types above. e.g. edit_button, delete_button, etc.

  If a navigate path is provided, an <a> tag will be used, otherwise a <button> tag will be used.

  ## Examples

      <.button style="primary" navigate={~p"/actors/new"} icon="hero-plus">
        Add user
      </.button>

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :navigate, :string,
    required: false,
    doc: """
    The path to navigate to, when set an <a> tag will be used,
    otherwise a <button> tag will be used
    """

  attr :class, :string, default: "", doc: "Custom classes to be added to the button"
  attr :style, :string, default: nil, doc: "The style of the button"
  attr :type, :string, default: nil, doc: "The button type"
  attr :size, :string, default: "md", doc: "The size of the button"

  attr :icon, :string,
    default: nil,
    required: false,
    doc: "The icon to be displayed on the button"

  attr :rest, :global, include: ~w(disabled form name value navigate)
  slot :inner_block, required: true, doc: "The label for the button"

  def button(%{navigate: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} navigate={@navigate} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
      <%= render_slot(@inner_block) %>
    </.link>
    """
  end

  def button(assigns) do
    ~H"""
    <button type={@type} class={button_style(@style) ++ button_size(@size) ++ [@class]} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
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

  attr :rest, :global
  slot :inner_block, required: true

  def submit_button(assigns) do
    ~H"""
    <.button style="primary" {@rest}>
      <%= render_slot(@inner_block) %>
    </.button>
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
    <.button style="danger" icon="hero-trash-solid" {@rest}>
      <%= render_slot(@inner_block) %>
    </.button>
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
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def add_button(assigns) do
    ~H"""
    <.button style="primary" class={@class} navigate={@navigate} icon="hero-plus">
      <%= render_slot(@inner_block) %>
    </.button>
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
    <.button style="primary" navigate={@navigate} icon="hero-pencil-solid">
      <%= render_slot(@inner_block) %>
    </.button>
    """
  end

  defp button_style do
    [
      "flex items-center justify-center",
      "rounded font-medium",
      "phx-submit-loading:opacity-75"
    ]
  end

  defp button_style("danger") do
    button_style() ++
      [
        "text-red-600",
        "border border-red-600",
        "hover:text-white hover:bg-red-600"
      ]
  end

  defp button_style(_style) do
    button_style() ++
      [
        "text-white",
        "bg-accent-450",
        "hover:bg-accent-700"
      ]
  end

  defp button_size(size) do
    text = %{
      "xs" => "text-xs",
      "sm" => "text-sm",
      "md" => "text-sm",
      "lg" => "text-base",
      "xl" => "text-base"
    }

    spacing = %{
      "xs" => "px-2 py-1",
      "sm" => "px-3 py-2",
      "md" => "px-4 py-2",
      "lg" => "px-5 py-3",
      "xl" => "px-6 py-3.5"
    }

    [text[size], spacing[size]]
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
