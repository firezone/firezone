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
    values:
      ~w(checkbox color date datetime-local email file hidden month number password
               range radio radio_button_group readonly search group_select select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :value_index, :integer, default: nil

  attr :inline_errors, :boolean,
    default: false,
    doc: "whether to display errors inline instead of below the input"

  attr :checked, :boolean, doc: "the checked flag for checkbox and radio inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(autocomplete cols disabled form list max maxlength min minlength
                pattern placeholder readonly required rows size step)

  attr :class, :string, default: "", doc: "the custom classes to be added to the input"

  slot :inner_block

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors =
      cond do
        not Phoenix.Component.used_input?(field) ->
          []

        not is_nil(assigns.value_index) ->
          Enum.filter(field.errors, fn {_error, meta} ->
            Keyword.get(meta, :validated_as) == :list and
              Keyword.get(meta, :at) == assigns.value_index
          end)

        true ->
          field.errors
      end
      |> Enum.map(&translate_error(&1))

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, errors)
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

  # radio with label
  def input(%{type: "radio", label: _label} = assigns) do
    ~H"""
    <div>
      <label class="flex items-center gap-2 text-neutral-900">
        <input
          type="radio"
          id={@id}
          name={@name}
          value={@value}
          checked={@checked}
          class={[
            "w-4 h-4 border-neutral-300",
            @class
          ]}
          {@rest}
        />
        {@label}
        {if @inner_block, do: render_slot(@inner_block)}
      </label>
    </div>
    """
  end

  # radio without label
  def input(%{type: "radio_button_group"} = assigns) do
    ~H"""
    <input
      type="radio"
      id={@id}
      name={@name}
      value={@value}
      checked={@checked}
      class={[
        "hidden peer",
        @class
      ]}
      {@rest}
    />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assigns
      |> assign_new(:checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns.value)
      end)
      |> assign_new(:value, fn ->
        "true"
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6 text-neutral-600">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value={@value}
          checked={@checked}
          class={[
            "bg-neutral-50",
            "border border-neutral-300 text-neutral-900 rounded",
            "checked:bg-accent-500 checked:hover:bg-accent-500",
            @class
          ]}
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  def input(%{type: "group_select"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        :if={not is_nil(@value) and @rest[:disabled] == true}
        type="hidden"
        name={@name}
        value={@value}
      />
      <select
        id={@id}
        name={@name}
        class={[
          "text-sm bg-neutral-50",
          "border border-neutral-300 text-neutral-900 rounded",
          "block p-2",
          !@inline_errors && "w-full",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>

        <%= for {label, options} <- @options do %>
          <%= if label == nil do %>
            {Phoenix.HTML.Form.options_for_select(options, @value)}
          <% else %>
            <optgroup label={label}>
              {Phoenix.HTML.Form.options_for_select(options, @value)}
            </optgroup>
          <% end %>
        <% end %>
      </select>
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        :if={@rest[:disabled] in [true, "true"] and not is_nil(@value)}
        type="hidden"
        name={@name}
        value={@value}
      />
      <select
        id={@id}
        name={@name}
        class={[
          "text-sm bg-neutral-50",
          "border border-neutral-300 text-neutral-900 rounded",
          "block p-2.5",
          !@inline_errors && "w-full",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label} for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "block rounded sm:text-sm sm:leading-6",
          "bg-neutral-50",
          "border border-neutral-300 rounded",
          "min-h-[6rem]",
          !@inline_errors && "w-full",
          @errors != [] && "border-rose-400 focus:border-rose-400",
          @class
        ]}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
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

  def input(%{type: "readonly"} = assigns) do
    ~H"""
    <div>
      <.label :if={@label}>{@label}</.label>
      <div class="border border-solid rounded p-2 text-sm text-neutral-500">
        {assigns.value}
      </div>
      <input
        type="hidden"
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        {@rest}
      />

      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  def input(%{type: "text", prefix: prefix} = assigns) when not is_nil(prefix) do
    ~H"""
    <div class={@inline_errors && "flex flex-row items-center"}>
      <.label :if={@label} for={@id}>{@label}</.label>
      <div class={[
        "flex",
        "text-sm text-neutral-900 bg-neutral-50",
        "border border-neutral-300 rounded",
        !@inline_errors && "w-full",
        "focus-within:outline-none focus-within:border-accent-600",
        "peer-disabled:bg-neutral-50 peer-disabled:text-neutral-500 peer-disabled:border-neutral-200 peer-disabled:shadow-none",
        @errors != [] && "border-rose-400 focus:border-rose-400"
      ]}>
        <span
          class={[
            "bg-neutral-100 whitespace-nowrap rounded-e-0 rounded-s inline-flex items-center px-3"
          ]}
          id={"#{@id}-prefix"}
          phx-hook="Refocus"
          data-refocus={@id}
        >
          {@prefix}
        </span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            "text-sm text-neutral-900 bg-transparent border-0",
            "flex-1 min-w-0 p-2.5 block w-full",
            "focus:outline-none focus:border-0 focus:ring-0",
            @class
          ]}
          {@rest}
        />
      </div>
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class={@inline_errors && "flex flex-row items-center"}>
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "block",
          !@inline_errors && "w-full",
          "p-2.5 rounded",
          "bg-neutral-50 text-neutral-900 text-sm",
          "border border-neutral-300",
          "disabled:bg-neutral-50 disabled:text-neutral-500 disabled:border-neutral-200 disabled:shadow-none",
          @errors != [] && "border-rose-400 focus:border-rose-400",
          @class
        ]}
        {@rest}
      />
      <.error :for={msg <- @errors} inline={@inline_errors} data-validation-error-for={@name}>
        {msg}
      </.error>
    </div>
    """
  end

  ### Switches ###

  @doc """
  Renders a checkbox disguised as a toggle switch.

  ## Examples

      <.switch field={@form[:email_opt_in]} />
      <.switch name="my-switch" />
  """

  attr :id, :any, default: nil
  attr :name, :string, default: nil
  attr :label, :string, default: nil
  attr :label_placement, :string, default: "right", values: ~w(left right)
  attr :checked, :boolean, default: false, doc: "the checked flag for the switch"

  attr :field, Phoenix.HTML.FormField,
    default: nil,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  def switch(assigns) do
    id = assigns.id || get_in(assigns, [:field, Access.key(:id)])
    name = assigns.name || get_in(assigns, [:field, Access.key(:name)])
    checked = assigns.checked || get_in(assigns, [:field, Access.key(:value)])

    assigns =
      assign(assigns,
        id: id,
        name: name,
        checked: checked
      )

    ~H"""
    <label class="inline-flex items-center cursor-pointer">
      <input type="checkbox" id={@id} class="sr-only peer" checked={@checked} name={@name} />
      <%= if @label_placement == "left" do %>
        <span class="ms-3 mr-3 text-sm font-medium text-neutral-900">{@label}</span>
      <% end %>
      <div class={~w(
        relative w-11 h-6 bg-neutral-200 peer-focus:outline-none
        peer-focus:ring-2 peer-focus:ring-accent-300 rounded-full
        peer peer-checked:after:translate-x-full rtl:peer-checked:after:-translate-x-full
        peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px]
        after:start-[2px] after:bg-white after:border-neutral-300 after:border
        after:rounded-full after:h-5 after:w-5 after:transition-all
        peer-checked:bg-accent-600
      )}></div>
      <%= if @label_placement == "right" do %>
        <span class="ms-3 ml-3 text-sm font-medium text-neutral-900">{@label}</span>
      <% end %>
    </label>
    """
  end

  ### Dialogs ###

  attr :id, :string, required: true, doc: "The id of the dialog"
  attr :class, :string, default: "", doc: "Custom classes to be added to the button"
  attr :style, :string, default: "danger", doc: "The style of the button"
  attr :confirm_style, :string, default: "danger", doc: "The style of the confirm button"
  attr :icon, :string, default: nil, doc: "The icon of the button"
  attr :size, :string, default: "md", doc: "The size of the button"
  attr :on_confirm, :string, required: true, doc: "The phx event to broadcast on confirm"
  attr :disabled, :boolean, default: false, doc: "Whether the button is disabled"

  attr :on_confirm_id, :string,
    default: nil,
    doc: "The phx event id value to broadcast on confirm"

  slot :dialog_title, doc: "The title of the dialog"
  slot :dialog_content, doc: "The content of the dialog"
  slot :dialog_confirm_button, doc: "The content of the confirm button of the dialog"
  slot :dialog_cancel_button, doc: "The content of the cancel button of the dialog"
  slot :inner_block, required: true, doc: "The label for the button"

  def button_with_confirmation(assigns) do
    ~H"""
    <dialog
      id={"#{@id}_dialog"}
      class={[
        "backdrop:bg-gray-800/75 bg-transparent",
        "p-4 w-full md:inset-0 max-h-full",
        "overflow-y-auto overflow-x-hidden"
      ]}
    >
      <form method="dialog" class="flex items-center justify-center">
        <div class="relative bg-white rounded-lg shadow max-w-2xl">
          <div class="flex items-center justify-between p-4 md:p-5 border-b rounded-t">
            <h3 class="text-xl font-semibold text-neutral-900">
              {render_slot(@dialog_title)}
            </h3>
            <button
              class="text-neutral-400 bg-transparent hover:text-accent-900 ml-2"
              type="submit"
              value="cancel"
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
              <span class="sr-only">Close modal</span>
            </button>
          </div>
          <div class="p-4 md:p-5 text-neutral-500 text-base">
            {render_slot(@dialog_content)}
          </div>
          <div class="flex items-center justify-end p-4 md:p-5 border-t border-gray-200 rounded-b">
            <.button
              data-dialog-action="cancel"
              type="submit"
              value="cancel"
              style="info"
              class="px-5 py-2.5"
            >
              {render_slot(@dialog_cancel_button)}
            </.button>
            <.button
              data-dialog-action="confirm"
              phx-click={@on_confirm}
              phx-value-id={@on_confirm_id}
              type="submit"
              style={@confirm_style}
              value="confirm"
              class="py-2.5 px-5 ms-3"
            >
              {render_slot(@dialog_confirm_button)}
            </.button>
          </div>
        </div>
      </form>
    </dialog>
    <.button
      id={@id}
      style={@style}
      size={@size}
      icon={@icon}
      class={@class}
      disabled={@disabled}
      phx-hook="ConfirmDialog"
    >
      {render_slot(@inner_block)}
    </.button>
    """
  end

  ### Buttons ###

  @doc """
  Base button type to be used directly or by the specialized button types above. e.g. edit_button, delete_button, etc.

  If a navigate, href, or patch path is provided, an <a> tag will be used, otherwise a <button> tag will be used.

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

  attr :href, :string,
    required: false,
    doc: """
    The path to redirect to using a full page reload, when set an <a> tag will be used,
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

  attr :rest, :global, include: ~w(disabled form name value navigate href)
  slot :inner_block, required: true, doc: "The label for the button"

  def button(%{href: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} href={@href} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def button(%{navigate: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} navigate={@navigate} {@rest}>
      <.icon :if={@icon} name={@icon} class="h-3.5 w-3.5 mr-2" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def button(assigns) do
    ~H"""
    <button type={@type} class={button_style(@style) ++ button_size(@size) ++ [@class]} {@rest}>
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
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

  attr :rest, :global, include: ~w(class icon)
  attr :style, :string, default: "primary", doc: "The style of the button"
  slot :inner_block, required: true

  def submit_button(assigns) do
    ~H"""
    <div class="flex justify-end">
      <.button type="submit" style={@style} {@rest}>
        {render_slot(@inner_block)}
      </.button>
    </div>
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
  attr :size, :string, default: "md", doc: "The size of the button"

  def delete_button(assigns) do
    ~H"""
    <.button style="danger" size={@size} icon="hero-trash-solid" {@rest}>
      {render_slot(@inner_block)}
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
      {render_slot(@inner_block)}
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
      {render_slot(@inner_block)}
    </.button>
    """
  end

  @doc """
  Renders a button group. Requires at least two :button slots to be passed.

  ## Examples

    <.button_group>
      <:button label="Cancel" />
      <.button label="Save" />
    </.button_group>
  """
  attr :style, :string, default: "info", doc: "The style of the button group"

  slot :button, required: true do
    attr :label, :string, required: true
    attr :icon, :string
    attr :event, :string
  end

  def button_group(assigns) do
    if Enum.count(assigns.button) < 2 do
      raise """
      The button group component requires at least two buttons to be passed.
      """
    end

    ~H"""
    <div class="inline-flex rounded" role="group">
      <%= for {button, index} <- Enum.with_index(@button) do %>
        <button
          type="button"
          class={button_group_style(@style, index, Enum.count(@button))}
          {if button[:event], do: %{"phx-click" => button[:event]}, else: %{}}
        >
          <%= if button[:icon] do %>
            <span class={button[:icon]}></span>
          <% end %>
          {button[:label]}
        </button>
      <% end %>
    </div>
    """
  end

  def button_group_style("disabled", idx, count) do
    ~w[cursor-not-allowed opacity-50] ++ button_group_style("info", idx, count)
  end

  def button_group_style("info", idx, count) do
    # TODO: more styles
    shared = ~w[
      phx-submit-loading:opacity-75
      px-3 py-2
      text-sm text-neutral-900
      bg-white border-neutral-200 hover:bg-neutral-100
    ]

    if idx == 0 do
      # first
      shared ++ ~w[border rounded-s]
    else
      if idx == count - 1 do
        # last
        shared ++ ~w[border rounded-e]
      else
        # middle
        shared ++ ~w[border-t border-b]
      end
    end
  end

  def button_style do
    [
      "flex items-center justify-center",
      "rounded",
      "phx-submit-loading:opacity-75"
    ]
  end

  def button_style("warning") do
    button_style() ++
      [
        "text-primary-500",
        "border border-primary-500",
        "hover:text-white hover:bg-primary-500"
      ]
  end

  def button_style("danger") do
    button_style() ++
      [
        "text-red-600",
        "border border-red-600",
        "hover:text-white hover:bg-red-600"
      ]
  end

  def button_style("info") do
    button_style() ++
      [
        "text-neutral-900",
        "border border-neutral-200",
        "hover:bg-neutral-100 hover:text-neutral-900"
      ]
  end

  def button_style("disabled") do
    button_style() ++
      [
        "text-neutral-200",
        "border border-neutral-200",
        "cursor-not-allowed"
      ]
  end

  def button_style(_style) do
    button_style() ++
      [
        "text-white",
        "bg-accent-450",
        "hover:bg-accent-700"
      ]
  end

  def button_size(size) do
    text = %{
      "xs" => "text-xs",
      "sm" => "text-sm",
      "md" => "text-sm",
      "lg" => "text-base",
      "xl" => "text-base"
    }

    spacing = %{
      "xs" => "px-1.5 py-1",
      "sm" => "px-2 py-2",
      "md" => "px-3 py-2",
      "lg" => "px-4 py-3",
      "xl" => "px-5 py-3.5"
    }

    [text[size], spacing[size]]
  end

  def icon_size(size) do
    icon_size = %{
      "xs" => "w-3 h-3",
      "sm" => "w-3 h-3",
      "md" => "w-3.5 h-3.5",
      "lg" => "w-4 h-4",
      "xl" => "w-5 h-5"
    }

    spacing = %{
      "xs" => "mr-1",
      "sm" => "mr-1.5",
      "md" => "mr-2",
      "lg" => "mr-3",
      "xl" => "mr-4"
    }

    [icon_size[size], spacing[size]]
  end
end
