defmodule PortalWeb.FormComponents do
  @moduledoc """
  Provides Form UI components.
  """
  use Phoenix.Component
  use PortalWeb, :verified_routes

  import PortalWeb.CoreComponents,
    only: [icon: 1, error: 1, label: 1, translate_error: 1, provider_icon: 1]

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

  attr :unchecked_value, :any,
    default: "false",
    doc: "the value to send when checkbox is unchecked"

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
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <input :if={@unchecked_value} type="hidden" name={@name} value={@unchecked_value} />
      <label class="flex items-center gap-4 text-sm leading-6 text-neutral-600">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
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
          "block",
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

  ### Dialogs ###

  @doc """
  Renders a modal dialog.

  ## Examples

      <.modal id="my-modal">
        <:title>Welcome</:title>
        <:body>
          This is the modal content.
        </:body>
        <:footer>
          <.button phx-click="close-modal">Close</.button>
        </:footer>
      </.modal>

      <.modal id="wizard-modal" on_back="prev-step" on_confirm="next-step">
        <:title>Step 1</:title>
        <:body>
          Complete this step.
        </:body>
        <:back_button>Previous</:back_button>
        <:confirm_button>Next</:confirm_button>
      </.modal>
  """
  attr :id, :string, required: true, doc: "The id of the modal"
  attr :class, :string, default: "", doc: "Custom classes to be added to the modal"

  attr :on_back, :string,
    default: nil,
    doc: "The phx event to broadcast when back button is clicked"

  attr :on_confirm, :string,
    default: nil,
    doc: "The phx event to broadcast when confirm button is clicked"

  attr :on_close, :string,
    default: nil,
    doc: "The phx event to broadcast when modal is closed"

  attr :confirm_style, :string, default: "primary", doc: "The style of the confirm button"

  attr :confirm_disabled, :boolean,
    default: false,
    doc: "Whether the confirm button is disabled"

  attr :confirm_button_title, :string,
    default: nil,
    doc: "The title attribute (tooltip) for the confirm button"

  slot :title, doc: "The title of the modal" do
    attr :icon, :atom, doc: "Optional icon to display before the title"
  end

  slot :body, required: true, doc: "The content of the modal"
  slot :footer, doc: "The footer of the modal (overrides back/confirm buttons if provided)"
  slot :back_button, doc: "The content of the back button"

  slot :confirm_button do
    attr :form, :string, doc: "The form id to associate with the button"
    attr :type, :string, doc: "The button type (button, submit, reset)"
  end

  def modal(assigns) do
    ~H"""
    <dialog
      id={@id}
      class={[
        "backdrop:bg-gray-800/75 bg-transparent",
        "p-4 w-full md:inset-0 max-h-full",
        "overflow-y-auto overflow-x-hidden",
        @class
      ]}
      phx-hook="Modal"
      phx-on-close={@on_close}
    >
      <div class="flex items-center justify-center">
        <div class="relative bg-white rounded-lg shadow w-full max-w-2xl" phx-click-away={@on_close}>
          <div
            :if={@title != []}
            class="flex items-center justify-between p-4 md:p-5 border-b rounded-t"
          >
            <h3 class="text-xl font-semibold text-neutral-900 flex items-center gap-3">
              <.provider_icon
                :for={title_slot <- @title}
                :if={Map.get(title_slot, :icon)}
                type={Map.get(title_slot, :icon)}
                class="w-8 h-8"
              />
              {render_slot(@title)}
            </h3>
            <button
              class="text-neutral-400 bg-transparent hover:text-accent-900 ml-2"
              type="button"
              phx-click={@on_close}
            >
              <.icon name="hero-x-mark" class="h-4 w-4" />
              <span class="sr-only">Close modal</span>
            </button>
          </div>
          <div class="p-4 md:p-5 text-neutral-500 text-base">
            {render_slot(@body)}
          </div>
          <div
            :if={@footer != [] or @back_button != [] or @confirm_button != []}
            class="flex items-center justify-between p-4 md:p-5 border-t border-gray-200 rounded-b gap-3"
          >
            <%= if @footer != [] do %>
              {render_slot(@footer)}
            <% else %>
              <.button
                :if={@back_button != []}
                phx-click={@on_back}
                type="button"
                style="info"
                class="px-5 py-2.5"
              >
                {render_slot(@back_button)}
              </.button>
              <div :if={@back_button == []}></div>
              <.button
                :for={confirm_slot <- @confirm_button}
                :if={@confirm_button != []}
                phx-click={@on_confirm}
                type={Map.get(confirm_slot, :type, "button")}
                form={Map.get(confirm_slot, :form)}
                style={@confirm_style}
                class="py-2.5 px-5"
                disabled={@confirm_disabled}
                title={@confirm_button_title}
                tabindex="0"
              >
                {render_slot(confirm_slot)}
              </.button>
            <% end %>
          </div>
        </div>
      </div>
    </dialog>
    """
  end

  attr :id, :string, required: true, doc: "The id of the dialog"
  attr :class, :string, default: "", doc: "Custom classes to be added to the button"
  attr :style, :string, default: "danger", doc: "The style of the button"
  attr :confirm_style, :string, default: "danger", doc: "The style of the confirm button"
  attr :icon, :string, default: nil, doc: "The icon of the button"
  attr :size, :string, default: "md", doc: "The size of the button"
  attr :type, :string, default: "button", doc: "The button type"
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
      type={@type}
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

  attr :patch, :string,
    required: false,
    doc: """
    The path to patch to using live navigation, when set a <.link> tag with patch will be used,
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

  attr :rest, :global, include: ~w(disabled form name value navigate href patch title)
  slot :inner_block, required: true, doc: "The label for the button"

  def button(%{href: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} href={@href} {@rest}>
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def button(%{navigate: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} navigate={@navigate} {@rest}>
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def button(%{patch: _} = assigns) do
    ~H"""
    <.link class={button_style(@style) ++ button_size(@size) ++ [@class]} patch={@patch} {@rest}>
      <.icon :if={@icon} name={@icon} class={icon_size(@size)} />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def button(assigns) do
    disabled = Map.get(assigns.rest, :disabled, false)
    style = if disabled, do: "disabled", else: assigns.style
    assigns = assign(assigns, :computed_style, style)

    ~H"""
    <button
      type={@type}
      class={button_style(@computed_style) ++ button_size(@size) ++ [@class]}
      {@rest}
    >
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

    <.add_button patch={~p"/actors/new"}>
      Add user
    </.add_button>
  """
  attr :navigate, :any, required: false, doc: "Path to navigate to"
  attr :patch, :any, required: false, doc: "Path to patch to"
  attr :class, :string, default: ""
  slot :inner_block, required: true

  def add_button(%{navigate: navigate} = assigns) when not is_nil(navigate) do
    ~H"""
    <.button style="primary" class={@class} navigate={@navigate} icon="hero-plus">
      {render_slot(@inner_block)}
    </.button>
    """
  end

  def add_button(%{patch: patch} = assigns) when not is_nil(patch) do
    ~H"""
    <.button style="primary" class={@class} patch={@patch} icon="hero-plus">
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
