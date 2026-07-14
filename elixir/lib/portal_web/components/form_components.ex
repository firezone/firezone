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
        resolve_field_value(field, assigns.value_id)
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
      <label class="flex items-center gap-2 text-heading">
        <input
          type="radio"
          id={@id}
          name={@name}
          value={@value}
          checked={@checked}
          class={[
            "w-4 h-4 border-input-border",
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
      <label class="flex items-center gap-4 text-sm leading-6 text-body">
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={[
            "bg-input",
            "border border-input-border text-heading rounded-sm",
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
          "text-sm py-2 pl-3 pr-8 rounded",
          "bg-raised text-body",
          "border border-border",
          "outline-none transition-colors cursor-pointer",
          "hover:border-border-emphasis hover:text-heading",
          "focus:border-border-focus focus:ring-1 focus:ring-border-focus/30",
          "block",
          !@inline_errors && "w-full",
          @errors != [] && "border-error focus:border-error",
          @class
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
          "text-sm py-2 pl-3 pr-8 rounded",
          "bg-raised text-body",
          "border border-border",
          "outline-none transition-colors cursor-pointer",
          "hover:border-border-emphasis hover:text-heading",
          "focus:border-border-focus focus:ring-1 focus:ring-border-focus/30",
          "block",
          !@inline_errors && "w-full",
          @errors != [] && "border-error focus:border-error",
          @class
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
          "block rounded-md text-sm px-3 py-2",
          "bg-input text-heading placeholder:text-muted",
          "border border-input-border",
          "outline-none transition-colors",
          "focus:border-border-focus focus:ring-1 focus:ring-border-focus/30",
          "min-h-[6rem]",
          !@inline_errors && "w-full",
          @errors != [] && "border-error focus:border-error",
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
      <div class="border border-input-border rounded-md px-3 py-2 text-sm text-subtle bg-raised">
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
          "px-3 py-2 rounded text-sm",
          "bg-input text-heading placeholder:text-muted",
          "border border-input-border",
          "outline-none transition-colors",
          "focus:border-border-focus focus:ring-1 focus:ring-border-focus/30",
          "disabled:opacity-40 disabled:cursor-not-allowed",
          @errors != [] && "border-error focus:border-error",
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

  defp resolve_field_value(field, value_id) do
    Enum.map(field.value, fn
      %Ecto.Changeset{} = value ->
        value |> Ecto.Changeset.apply_changes() |> value_id.()

      value ->
        value_id.(value)
    end)
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
    attr :provider, :string, doc: "Optional provider icon to display before the title"
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
        "w-full md:inset-0 max-h-full",
        "overflow-y-auto overflow-x-hidden",
        @class
      ]}
      phx-hook="Modal"
      phx-on-close={@on_close}
    >
      <div class="flex items-center justify-center min-h-screen p-4">
        <div
          class="relative bg-white rounded-md shadow-sm w-full max-w-2xl"
          phx-click-away={@on_close}
        >
          <div
            :if={@title != []}
            class="flex items-center justify-between p-4 md:p-5 border-b border-neutral-200 rounded-t"
          >
            <h3 class="text-xl font-semibold text-neutral-900 flex items-center gap-3">
              <.provider_icon
                :for={title_slot <- @title}
                :if={Map.get(title_slot, :provider)}
                provider={Map.get(title_slot, :provider)}
                size="xl"
              />
              {render_slot(@title)}
            </h3>
            <button
              class="text-neutral-400 bg-transparent hover:text-accent-900 ml-2"
              type="button"
              phx-click={@on_close}
            >
              <.icon name="ri-close-line" class="h-4 w-4" />
              <span class="sr-only">Close modal</span>
            </button>
          </div>
          <div class="p-4 md:p-5 text-neutral-500 text-base">
            {render_slot(@body)}
          </div>
          <div
            :if={@footer != [] or @back_button != [] or @confirm_button != []}
            class="flex items-center justify-between p-4 md:p-5 border-t border-neutral-200 rounded-b gap-3"
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
        "w-full md:inset-0 max-h-full",
        "overflow-y-auto overflow-x-hidden"
      ]}
    >
      <form method="dialog" class="flex items-center justify-center min-h-screen p-4">
        <div class="relative bg-elevated border border-border rounded-md shadow-sm max-w-2xl">
          <div class="flex items-center justify-between p-4 md:p-5 border-b border-border rounded-t">
            <h3 class="text-xl font-semibold text-heading">
              {render_slot(@dialog_title)}
            </h3>
            <button
              class="text-subtle bg-transparent hover:text-heading ml-2"
              type="submit"
              value="cancel"
            >
              <.icon name="ri-close-line" class="h-4 w-4" />
              <span class="sr-only">Close modal</span>
            </button>
          </div>
          <div class="p-4 md:p-5 text-body text-base">
            {render_slot(@dialog_content)}
          </div>
          <div class="flex items-center justify-end p-4 md:p-5 border-t border-border rounded-b">
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

      <.button style="primary" navigate={~p"/actors/new"} icon="ri-add-line">
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
  Renders an icon-only button. Use for actions that are obvious from context
  (e.g., close/dismiss). Always provide `title` for hover tooltip and accessibility.

  ## Examples

      <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" />
      <.icon_button style="outline" icon="ri-arrow-left-s-line" title="Previous page" phx-click="prev_page" disabled={@page <= 1} />
      <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_panel" size="sm" class="shrink-0" />
  """
  attr :icon, :string, required: true, doc: "The remix icon name"
  attr :title, :string, default: nil, doc: "Tooltip shown on hover (recommended for accessibility)"
  attr :style, :string, default: nil, doc: "Visual style: nil (ghost) | \"outline\""
  attr :size, :string, default: "md", doc: "Button size: xs | sm | md | lg | xl"
  attr :class, :string, default: "", doc: "Extra CSS classes (e.g. shrink-0)"
  attr :rest, :global, include: ~w(disabled form name value phx-target)

  def icon_button(assigns) do
    ~H"""
    <button
      type="button"
      class={
        ["flex items-center justify-center rounded transition-colors disabled:opacity-30 disabled:cursor-not-allowed"] ++
          icon_button_container_size(@size) ++
          icon_button_style(@style) ++
          [@class]
      }
      title={@title}
      aria-label={@title}
      {@rest}
    >
      <.icon name={@icon} class={icon_button_icon_size(@size)} />
    </button>
    """
  end

  defp icon_button_style(nil) do
    ["text-subtle hover:text-heading hover:bg-raised"]
  end

  defp icon_button_style("outline") do
    ["border border-border text-body hover:text-heading hover:border-border-emphasis"]
  end

  defp icon_button_container_size(size) do
    container = %{
      "xs" => "w-5 h-5",
      "sm" => "w-6 h-6",
      "md" => "w-7 h-7",
      "lg" => "w-8 h-8",
      "xl" => "w-9 h-9"
    }

    [container[size]]
  end

  defp icon_button_icon_size(size) do
    icon = %{
      "xs" => "w-3 h-3",
      "sm" => "w-3.5 h-3.5",
      "md" => "w-4 h-4",
      "lg" => "w-5 h-5",
      "xl" => "w-6 h-6"
    }

    icon[size]
  end

  @doc """
  Renders a full-width action button with an optional leading icon and style variants.
  """
  attr :type, :string, default: "button"
  attr :icon, :string, default: nil
  attr :style, :string, default: nil
  attr :size, :string, default: "sm"
  attr :class, :string, default: "", doc: "Custom classes to be added to the button"
  attr :rest, :global, include: ~w(disabled form name value title)

  slot :inner_block, required: true, doc: "The label for the button"

  def action_button(assigns) do
    ~H"""
    <button
      type={@type}
      class={action_button_style(@style) ++ button_size(@size) ++ [@class]}
      {@rest}
    >
      <.icon :if={@icon} name={@icon} class="w-3.5 h-3.5" />
      <span>{render_slot(@inner_block)}</span>
    </button>
    """
  end

  @doc """
  Renders a locked section with an upgrade banner and a blurred preview of the
  feature content underneath, all wrapped in a single container.

  ## Examples

      <.upgrade_locked_section
        account={@account}
        message="Upgrade your plan to unlock policy conditions."
        description="Add policy restrictions like IP ranges, identity providers, and time windows."
      >
        <.placeholder_or_preview />
      </.upgrade_locked_section>
  """
  attr :account, :any, required: true
  attr :message, :string, required: true
  attr :description, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def upgrade_locked_section(assigns) do
    ~H"""
    <div id={@id} class={["relative", @class]} {@rest}>
      <div class="absolute inset-0 z-20 flex items-center justify-center p-3">
        <div class="flex max-w-xs flex-col items-center gap-2 rounded-lg border border-border bg-elevated px-4 py-3 text-center text-subtle shadow-md">
          <.icon name="ri-lock-2-line" class="h-5 w-5" />
          <div class="flex flex-col items-center gap-0.5">
            <p class="text-xs font-medium text-heading">
              {@message}
            </p>
            <p :if={@description} class="text-[11px]">
              {@description}
            </p>
          </div>
          <.button
            style="primary"
            size="xs"
            icon="ri-sparkling-fill"
            navigate={~p"/#{@account}/settings/account"}
          >
            Upgrade to Unlock
          </.button>
        </div>
      </div>
      <div class="pointer-events-none absolute inset-0 z-10 rounded-xl bg-elevated/40" />
      <div class="pointer-events-none select-none rounded-xl border border-border bg-surface p-3 blur-[2px] opacity-70">
        {render_slot(@inner_block)}
      </div>
    </div>
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
    <.button style="danger" size={@size} icon="ri-delete-bin-fill" {@rest}>
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
    <.button style="primary" class={@class} navigate={@navigate} icon="ri-add-line">
      {render_slot(@inner_block)}
    </.button>
    """
  end

  def add_button(%{patch: patch} = assigns) when not is_nil(patch) do
    ~H"""
    <.button style="primary" class={@class} patch={@patch} icon="ri-add-line">
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
    <.button style="primary" navigate={@navigate} icon="ri-pencil-fill">
      {render_slot(@inner_block)}
    </.button>
    """
  end

  def button_style do
    [
      "flex items-center justify-center gap-1",
      "rounded",
      "phx-submit-loading:opacity-75"
    ]
  end

  def button_style("primary") do
    button_style() ++
      [
        "text-white",
        "bg-brand",
        "border border-brand",
        "hover:border-brand-dark hover:bg-brand-dark"
      ]
  end

  def button_style("secondary") do
    button_style() ++
      [
        "text-white",
        "bg-accent",
        "border border-accent",
        "hover:border-accent-dark hover:bg-accent-dark"
      ]
  end

  def button_style("success") do
    button_style() ++
      [
        "text-success",
        "bg-surface",
        "border border-success",
        "hover:bg-success-light"
      ]
  end

  def button_style("info") do
    button_style() ++
      [
        "text-info",
        "bg-surface",
        "border border-info",
        "hover:bg-info-light"
      ]
  end

  def button_style("warning") do
    button_style() ++
      [
        "text-warning",
        "bg-surface",
        "border border-warning",
        "hover:bg-warning-light"
      ]
  end

  def button_style("danger") do
    button_style() ++
      [
        "text-danger",
        "bg-surface",
        "border border-danger/40",
        "hover:bg-danger-light"
      ]
  end

  def button_style("disabled") do
    button_style() ++
      [
        "text-muted",
        "border border-border",
        "cursor-not-allowed"
      ]
  end

  def button_style(_style) do
    button_style() ++
      [
        "text-body",
        "bg-surface",
        "border border-border-strong",
        "hover:bg-raised hover:text-heading"
      ]
  end

  def action_button_style(nil), do: action_button_base() ++ ["text-body", "hover:text-heading", "hover:bg-raised"]
  def action_button_style("info"), do: action_button_base() ++ ["text-info", "hover:bg-raised"]
  def action_button_style("success"), do: action_button_base() ++ ["text-success", "hover:bg-raised"]
  def action_button_style("warning"), do: action_button_base() ++ ["text-warning", "hover:bg-raised"]

  def action_button_style(style) when style in ["error", "danger"] do
    action_button_base() ++ ["text-error", "border", "border-error/20", "hover:bg-error-light"]
  end

  defp action_button_base do
    ["flex items-center gap-2", "rounded", "w-full", "bg-surface", "transition-colors"]
  end

  def button_size(size) do
    text = %{
      "xs" => "text-xs",
      "sm" => "text-xs",
      "md" => "text-sm",
      "lg" => "text-base",
      "xl" => "text-base"
    }

    spacing = %{
      "xs" => "px-2 py-1",
      "sm" => "px-3 py-1.5",
      "md" => "px-3 py-2",
      "lg" => "px-4 py-3",
      "xl" => "px-5 py-3.5"
    }

    [text[size], spacing[size]]
  end

  def icon_size(size) do
    icon_size = %{
      "xs" => "w-3 h-3",
      "sm" => "w-3.5 h-3.5",
      "md" => "w-3.5 h-3.5",
      "lg" => "w-4 h-4",
      "xl" => "w-5 h-5"
    }

    [icon_size[size]]
  end
end
