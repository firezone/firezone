defmodule PortalWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The components in this module use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn how to
  customize the generated components in this module.

  Icons are provided by [heroicons](https://heroicons.com), using the
  [heroicons_elixir](https://github.com/mveytsman/heroicons_elixir) project.
  """
  use Phoenix.Component
  use PortalWeb, :verified_routes
  alias Phoenix.LiveView.JS

  attr :text, :string, default: "Welcome to Firezone."

  def hero_logo(assigns) do
    ~H"""
    <div class="mb-6">
      <img src={~p"/images/logo.svg"} class="mx-auto pr-10 h-24" alt="Firezone Logo" />
      <p class="text-center mt-4 text-3xl">
        {@text}
      </p>
    </div>
    """
  end

  def logo(assigns) do
    ~H"""
    <a href={~p"/"} class="flex items-center mb-6 text-2xl">
      <img src={~p"/images/logo.svg"} class="mr-3 h-8" alt="Firezone Logo" />
      <span class="self-center text-2xl font-medium whitespace-nowrap">
        Firezone
      </span>
    </a>
    """
  end

  attr :account, :any, required: true
  attr :device, :any, required: true
  attr :class, :any, default: nil

  def device_link(assigns) do
    assigns = assign(assigns, :path, device_path(assigns.account, assigns.device))

    ~H"""
    <.link navigate={@path} class={@class}>
      {device_name(@device)}
    </.link>
    """
  end

  def device_name(%Portal.Device{type: :gateway, site: %Portal.Site{name: site_name}, name: name})
      when not is_nil(site_name) do
    "#{site_name}-#{name}"
  end

  def device_name(%Portal.Device{name: name}) when not is_nil(name), do: name

  defp device_path(account, %Portal.Device{type: :client, id: id}),
    do: ~p"/#{account}/clients/#{id}"

  defp device_path(account, %Portal.Device{type: :gateway}),
    do: ~p"/#{account}"

  @doc """
  Renders an inline code tag with formatting.

  ## Examples

  <.code>def foo: do :bar</.code>
  """
  attr :id, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true
  attr :rest, :global

  def code(assigns) do
    assigns =
      assign(
        assigns,
        :class,
        "#{assigns.class} font-semibold px-2 p-[0.15rem] bg-neutral-100 rounded-sm"
      )

    # Important: leave the </code> on the same line as the render_slot call, otherwise there will be
    # an undesired trailing space in the output.
    ~H"""
    <code id={@id} class={@class} {@rest} phx-no-format>
      {render_slot(@inner_block)}</code>
    """
  end

  @doc """
  Render a monospace code block suitable for copying and pasting content.

  ## Examples

  <.code_block id="foo">
    The lazy brown fox jumped over the quick dog.
  </.code_block>
  """
  attr :id, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true
  attr :rest, :global

  def code_block(assigns) do
    ~H"""
    <div id={@id} class="relative" phx-hook="CopyClipboard">
      <div id={"#{@id}-nested"} class={[~w[
        text-sm text-left text-neutral-50
        inline-flex items-center
        space-x-4 p-4 pl-6
        bg-neutral-800
        overflow-x-auto
      ], @class]} {@rest}>
        <code
          id={"#{@id}-code"}
          class="block w-full no-scrollbar whitespace-pre rounded-b"
          phx-no-format
        ><%= render_slot(@inner_block) %></code>
      </div>

      <button
        type="button"
        data-copy-to-clipboard-target={"#{@id}-code"}
        class={~w[
          absolute end-1 top-1 text-gray-900 hover:bg-gray-100
          rounded-sm py-2 px-2.5 inline-flex items-center justify-center
          bg-white border-neutral-200 border h-8
        ]}
      >
        <span id={"#{@id}-default-message"} class="inline-flex items-center">
          <.icon name="ri-clipboard-line" data-icon class="h-4 w-4 me-1.5" />
          <span class="text-xs font-semibold">Copy</span>
        </span>
        <span id={"#{@id}-success-message"} class="hidden items-center">
          <.icon name="ri-check-line" data-icon class="text-green-700 h-4 w-4 me-1.5" />
          <span class="text-xs font-semibold text-green-700">Copied</span>
        </span>
      </button>
    </div>
    """
  end

  @doc """
  Render an inlined copy-paste button to the right of the content block.

  ## Examples

  <.copy id="foo">
    The lazy brown fox jumped over the quick dog.
  </.copy>
  """
  attr :id, :string, required: true
  attr :class, :string, default: ""
  slot :inner_block, required: true
  attr :rest, :global

  def copy(assigns) do
    ~H"""
    <div id={@id} class={@class} phx-hook="CopyClipboard" {@rest}>
      <code id={"#{@id}-code"} phx-no-format><%= render_slot(@inner_block) %></code>
      <button
        type="button"
        class={~w[text-neutral-400 cursor-pointer rounded]}
        data-copy-to-clipboard-target={"#{@id}-code"}
        title="Copy to clipboard"
      >
        <.icon name="ri-clipboard-line" data-icon class="h-4 w-4" />
      </button>
    </div>
    """
  end

  @doc """
  Render a section header. Section headers are used in the main content section
  to provide a title for the content and option actions button(s) aligned on the right.

  ## Examples

    <.section>
      <:title>
        All gateways
      </:title>
      <:actions>
        <.add_button navigate={~p"/gateways/new"}>
          Deploy gateway
        </.add_button>
      </:actions>
    </.section>
  """
  slot :title, required: true, doc: "Title of the section"
  slot :actions, required: false, doc: "Buttons or other action elements"
  slot :help, required: false, doc: "A slot for help text to be displayed blow the title"

  def header(assigns) do
    ~H"""
    <div class="py-4 px-1 md:py-6">
      <div class="grid grid-cols-1 xl:grid-cols-3 xl:gap-4">
        <div class="col-span-full">
          <div class="flex justify-between items-center">
            <h2 class="text-2xl leading-none tracking-tight text-neutral-900">
              {render_slot(@title)}
            </h2>
            <div class="inline-flex justify-between items-center space-x-2">
              {render_slot(@actions)}
            </div>
          </div>
        </div>
      </div>
      <div :for={help <- @help} class="pt-3 text-neutral-400">
        {render_slot(help)}
      </div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  Can be displayed inline (default) or as a toast notification.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} style="toast" flash={@flash} />
      <.flash kind={:error}>Something went wrong!</.flash>
  """
  attr :id, :string, default: nil, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil

  attr :kind, :atom,
    values: [
      :success,
      :info,
      :warning,
      :error,
      :success_inline,
      :info_inline,
      :warning_inline,
      :error_inline
    ],
    doc: "used for styling and flash lookup"

  attr :class, :any, default: nil
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  attr :style, :string,
    default: "inline",
    values: ["inline", "toast", "wide"],
    doc: "inline for regular flash, toast for floating popover"

  attr :autoshow, :boolean, default: true, doc: "whether to automatically show and hide the toast"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    # Normalize kind for styling (map _inline variants to base types)
    base_kind =
      case assigns.kind do
        :success_inline -> :success
        :info_inline -> :info
        :warning_inline -> :warning
        :error_inline -> :error
        other -> other
      end

    assigns = assign(assigns, :base_kind, base_kind)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      popover={if @style == "toast", do: "manual", else: nil}
      class={[
        "p-4 text-sm flash-#{@kind}",
        @base_kind == :success && "text-success border-success/30",
        @base_kind == :info && "text-info border-info/30",
        @base_kind == :warning && "text-warning border-warning/30",
        @base_kind == :error && "text-error border-error/30",
        @style == "inline" && @base_kind == :success && "bg-success-light",
        @style == "inline" && @base_kind == :info && "bg-info-light",
        @style == "inline" && @base_kind == :warning && "bg-warning-light",
        @style == "inline" && @base_kind == :error && "bg-error-light",
        @style == "toast" && @base_kind == :success && "bg-[var(--toast-bg-success)]",
        @style == "toast" && @base_kind == :info && "bg-[var(--toast-bg-info)]",
        @style == "toast" && @base_kind == :warning && "bg-[var(--toast-bg-warn)]",
        @style == "toast" && @base_kind == :error && "bg-[var(--toast-bg-error)]",
        @style == "toast" && "m-0 border rounded-sm shadow-md",
        @style == "inline" && "mb-6 rounded-sm border",
        @class
      ]}
      role="alert"
      phx-hook={if @style == "toast", do: "Toast", else: nil}
      data-autoshow={if @style == "toast", do: to_string(@autoshow), else: nil}
      {@rest}
    >
      <div class={["flex items-start gap-2", @style == "toast" && ""]}>
        <.icon
          :if={@base_kind == :info}
          name="ri-information-line"
          class="h-4 w-4 shrink-0 mt-0.5"
        />
        <.icon
          :if={@base_kind == :success}
          name="ri-checkbox-circle-line"
          class="h-4 w-4 shrink-0 mt-0.5"
        />
        <.icon
          :if={@base_kind == :warning}
          name="ri-error-warning-line"
          class="h-4 w-4 shrink-0 mt-0.5"
        />
        <.icon
          :if={@base_kind == :error}
          name="ri-alert-line"
          class="h-4 w-4 shrink-0 mt-0.5"
        />
        <div class="flex-1 min-w-0">
          <p :if={@title} class="font-semibold leading-6 mb-1">{@title}</p>
          {maybe_render_changeset_as_flash(msg)}
        </div>
        <button
          :if={@style == "toast"}
          type="button"
          class="text-current opacity-50 hover:opacity-100 shrink-0"
          popovertarget={@id}
          popovertargetaction="hide"
          aria-label="Close"
        >
          <.icon name="ri-close-line" class="h-4 w-4" />
        </button>
      </div>
    </div>
    """
  end

  def maybe_render_changeset_as_flash({:validation_errors, message, errors}) do
    assigns = %{message: message, errors: errors}

    ~H"""
    {@message}:
    <ul>
      <li :for={{field, field_errors} <- @errors}>
        {field}: {Enum.join(field_errors, ", ")}
      </li>
    </ul>
    """
  end

  def maybe_render_changeset_as_flash(other) do
    other
  end

  @doc """
  Renders a standard form label.
  """
  attr :for, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label
      for={@for}
      class={["block text-xs font-semibold text-body mb-1.5", @class]}
    >
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  attr :inline, :boolean, default: false

  def error(assigns) do
    ~H"""
    <p
      class={[
        "flex items-center gap-2 text-sm leading-6",
        "text-error",
        (@inline && "ml-2") || "mt-2 w-full",
        @class
      ]}
      {@rest}
    >
      <.icon name="ri-alert-line" class="h-4 w-4 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Generates an error message for a form where it's not related to a specific field but rather to the form itself,
  eg. when there is an internal error during API call or one fields not rendered as a form field is invalid.

  ### Examples

      <.base_error form={@form} field={:base} />
  """
  attr :form, :any, required: true, doc: "the form"
  attr :field, :atom, doc: "field name"
  attr :rest, :global

  def base_error(assigns) do
    assigns = assign_new(assigns, :error, fn -> assigns.form.errors[assigns.field] end)

    ~H"""
    <p
      :if={@error}
      data-validation-error-for={"#{@form.id}[#{@field}]"}
      class="mt-3 mb-3 flex gap-3 text-m leading-6 text-rose-600"
      {@rest}
    >
      <.icon name="ri-alert-line" class="mt-0.5 h-5 w-5 flex-none" />
      {translate_error(@error)}
    </p>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title"><%= @post.title %></:item>
        <:item title="Views"><%= @post.views %></:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="mt-14">
      <dl class="-my-4 divide-y divide-neutral-100">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-neutral-500">{item.title}</dt>
          <dd class="text-neutral-700">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a [Hero Icon](https://heroicons.com) or [Remix Icon](https://remixicon.com).

  Hero icons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  Remix icons come in two styles – fill and line – applied via the
  `-fill` and `-line` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from `assets/vendor/heroicons` and `assets/vendor/remix_icons`
  and bundled within your compiled app.css by the plugins in `assets/tailwind.config.js`.

  ## Examples

      <.icon name="ri-close-fill" />
      <.icon name="ri-loop-left-line" class="ml-1 w-3 h-3 animate-spin" />
      <.icon name="ri-user-fill" class="w-5 h-5" />
      <.icon name="ri-settings-3-line" class="w-4 h-4 text-gray-500" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(%{name: "ri-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  def icon(%{name: "icon-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  def icon(%{name: "firezone"} = assigns) do
    ~H"""
    <img src={~p"/images/logo.svg"} class={["inline-block", @class]} {@rest} />
    """
  end

  @doc """
  Renders a user avatar from either its identity picture or its gravatar.
  """
  attr :actor, :any, required: true
  attr :size, :integer, required: true
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  def avatar(assigns) do
    ~H"""
    <img src={build_gravatar_url(@actor, @size)} {@rest} />
    """
  end

  defp build_gravatar_url(actor, size) do
    email = actor.email
    hash = Base.encode16(:crypto.hash(:md5, email), case: :lower)
    "https://www.gravatar.com/avatar/#{hash}?s=#{size}&d=retro"
  end

  @doc """
  Intersperses separator slot between a list of items.

  Useful when you need to add a separator between items such as when
  rendering breadcrumbs for navigation. Provides each item to the
  inner block.

  ## Examples

  ```heex
  <.intersperse_blocks>
    <:separator>
      <span class="sep">|</span>
    </:separator>

    <:empty>
      nothing
    </:empty>

    <:item>
      home
    </:item>

    <:item>
      profile
    </:item>

    <:item>
      settings
    </:item>
  </.intersperse_blocks>
  ```
  """
  slot :separator, required: false, doc: "the slot for the separator"
  slot :item, required: true, doc: "the slots to intersperse with separators"
  slot :empty, required: false, doc: "the slots to render when there are no items"

  def intersperse_blocks(assigns) do
    ~H"""
    <%= if Enum.empty?(@item) do %>
      {render_slot(@empty)}
    <% else %>
      <%= for item <- Enum.intersperse(@item, :separator) do %>
        <%= if item == :separator do %>
          {render_slot(@separator)}
        <% else %>
          {render_slot(
            item,
            cond do
              item == List.first(@item) -> :first
              item == List.last(@item) -> :last
              true -> :middle
            end
          )}
        <% end %>
      <% end %>
    <% end %>
    """
  end

  attr :type, :string, default: "neutral"
  attr :size, :string, default: "sm", values: ["xs", "sm", "md"]
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    colors = %{
      "success" => "bg-success-light text-success",
      "danger" => "bg-danger-light text-danger",
      "warning" => "bg-warning-light text-warning",
      "info" => "bg-info-light text-info",
      "primary" => "bg-brand-subtle text-brand",
      "accent" => "bg-accent-subtle text-accent",
      "neutral" => "bg-neutral-100 text-neutral-700"
    }

    sizes = %{
      "xs" => "text-[10px] px-1.5 py-px",
      "sm" => "text-xs px-2.5 py-0.5",
      "md" => "text-sm px-3 py-1"
    }

    assigns = assign(assigns, colors: colors, sizes: sizes)

    ~H"""
    <span
      class={[
        "rounded whitespace-nowrap",
        @sizes[@size],
        @colors[@type],
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :type, :string, default: "neutral"

  slot :left, required: true
  slot :right, required: true

  def dual_badge(assigns) do
    colors = %{
      "success" => %{
        "dark" => "bg-green-300 text-green-800",
        "light" => "bg-success-light text-success"
      },
      "danger" => %{
        "dark" => "bg-red-300 text-red-800",
        "light" => "bg-danger-light text-danger"
      },
      "warning" => %{
        "dark" => "bg-yellow-300 text-yellow-800",
        "light" => "bg-warning-light text-warning"
      },
      "info" => %{
        "dark" => "bg-blue-300 text-blue-800",
        "light" => "bg-info-light text-info"
      },
      "primary" => %{
        "dark" => "bg-primary-400 text-primary-800",
        "light" => "bg-brand-subtle text-brand"
      },
      "accent" => %{
        "dark" => "bg-accent-100 text-accent-800",
        "light" => "bg-accent-light text-accent"
      },
      "neutral" => %{
        "dark" => "bg-neutral-100 text-neutral-800",
        "light" => "bg-neutral-50 text-neutral-800"
      }
    }

    assigns = assign(assigns, colors: colors)

    ~H"""
    <div class="inline-flex">
      <span class={[
        "text-xs rounded-l py-0.5 px-2",
        @colors[@type]["dark"]
      ]}>
        {render_slot(@left)}
      </span>
      <span class={[
        "text-xs",
        "rounded-r",
        "py-0.5 px-2",
        @colors[@type]["light"]
      ]}>
        {render_slot(@right)}
      </span>
    </div>
    """
  end

  @doc """
  Renders datetime field in a format that is suitable for the user's locale.
  """
  attr :datetime, DateTime, required: true

  def datetime(assigns) do
    ~H"""
    <span title={@datetime}>
      {PortalWeb.Format.short_datetime(@datetime)}
    </span>
    """
  end

  @doc """
  Returns a string that represents a relative time for a given DateTime
  from the current time or a given base time
  """
  attr :datetime, DateTime, default: nil
  attr :relative_to, DateTime, required: false
  attr :negative_class, :string, default: ""
  attr :popover, :boolean, default: true
  attr :empty, :string, default: "Never"

  def relative_datetime(assigns) do
    assigns =
      assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    assigns =
      assigns
      |> assign(:has_datetime?, not is_nil(assigns.datetime))
      |> assign(:relative_datetime_text, relative_datetime_text(assigns))

    ~H"""
    <.popover :if={@has_datetime? and @popover}>
      <:target>
        <span class={[
          "underline underline-offset-2 decoration-1 decoration-dotted",
          DateTime.compare(@datetime, @relative_to) == :lt && @negative_class
        ]}>
          {@relative_datetime_text}
        </span>
      </:target>
      <:content>
        {@datetime}
      </:content>
    </.popover>
    <span :if={@has_datetime? and not @popover}>
      {@relative_datetime_text}
    </span>
    <span :if={not @has_datetime?}>
      {@empty}
    </span>
    """
  end

  defp relative_datetime_text(%{datetime: nil}), do: nil

  defp relative_datetime_text(%{datetime: datetime, relative_to: relative_to}) do
    datetime
    |> PortalWeb.Format.relative_datetime(relative_to)
    |> String.capitalize()
  end

  @doc """
  Renders a popover element with title and content.
  """
  attr :placement, :string, default: "top"
  attr :trigger, :string, default: "hover"
  slot :target, required: true
  slot :content, required: true

  def popover(assigns) do
    # Any id will do
    target_id = "popover-#{System.unique_integer([:positive, :monotonic])}"

    assigns =
      assigns
      |> assign(:target_id, target_id)
      |> assign_new(:trigger, fn -> "hover" end)
      |> assign(:menu?, assigns[:trigger] == "click")

    ~H"""
    <span
      phx-hook="Popover"
      id={@target_id <> "-trigger"}
      data-popover-target-id={@target_id}
      data-popover-placement={@placement}
      data-popover-trigger={@trigger}
      aria-describedby={if not @menu?, do: @target_id}
      tabindex={if not @menu?, do: "0"}
    >
      {render_slot(@target)}
    </span>

    <div
      data-popover
      id={@target_id}
      role={if @menu?, do: "menu", else: "tooltip"}
      class={~w[
        fixed z-10 invisible inline-block
        text-xs text-neutral-500 transition-opacity
        duration-50 bg-white border border-neutral-200
        rounded-md shadow-xs opacity-0
      ]}
    >
      <div class="px-3 py-2">
        {render_slot(@content)}
      </div>
      <div data-popper-arrow></div>
    </div>
    """
  end

  @doc """
  Renders an actions dropdown shell with a standard overflow trigger.
  """
  attr :open, :boolean, required: true
  attr :close_event, :string, required: true
  attr :button_class, :any,
    default:
      "flex items-center justify-center w-7 h-7 rounded text-subtle hover:text-heading hover:bg-raised transition-colors"
  attr :menu_class, :any,
    default:
      "absolute right-0 top-full mt-1 w-44 rounded-md border border-border bg-elevated shadow-lg z-10 py-1"
  attr :icon_class, :string, default: "w-4 h-4"
  attr :trigger_icon, :string, default: "ri-more-2-line"
  attr :rest, :global
  slot :inner_block, required: true

  def actions_dropdown(assigns) do
    ~H"""
    <div class="relative shrink-0">
      <button type="button" class={@button_class} {@rest}>
        <.icon name={@trigger_icon} class={@icon_class} />
      </button>
      <div :if={@open} phx-click-away={@close_event} class={@menu_class}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders online or offline status using an `online?` field of the schema.
  """
  attr :schema, :any, required: true
  attr :class, :any, default: nil

  def connection_status(assigns) do
    assigns = assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    last_seen_at =
      if Map.has_key?(assigns.schema, :latest_session) do
        session = Map.get(assigns.schema, :latest_session)
        session && session.timestamp
      else
        assigns.schema.last_seen_at
      end

    assigns = assign(assigns, :display_last_seen_at, last_seen_at)

    ~H"""
    <span class={["flex items-center", @class]}>
      <.ping_icon color={if @schema.online?, do: "success", else: "danger"} />
      <span
        class="ml-2.5"
        title={
          if @display_last_seen_at,
            do:
              "Last started #{PortalWeb.Format.relative_datetime(@display_last_seen_at, @relative_to)}",
            else: "Never connected"
        }
      >
        {if @schema.online?, do: "Online", else: "Offline"}
      </span>
    </span>
    """
  end

  @doc """
  Renders online or offline status using an `online?` field of the schema.
  """
  attr :schema, :any, required: true

  def online_icon(assigns) do
    ~H"""
    <span :if={@schema.online?} class="inline-flex rounded-full h-2.5 w-2.5 bg-green-500"></span>
    """
  end

  attr :navigate, :string, required: true
  attr :connected?, :boolean, required: true
  attr :type, :string, required: true

  def initial_connection_status(assigns) do
    ~H"""
    <.link
      class={[
        "px-4 py-2",
        "flex items-center",
        "text-sm text-white",
        "rounded",
        "transition-colors",
        (@connected? && "bg-accent-450 hover:bg-accent-700") || "bg-primary-500 cursor-progress"
      ]}
      navigate={@navigate}
      {
        if @connected? do
          %{}
        else
          %{"data-confirm" => "Do you want to skip waiting for #{@type} to be connected?"}
        end
      }
    >
      <span :if={not @connected?}>
        <.icon name="icon-spinner" class="animate-spin h-3.5 w-3.5 mr-1" /> Waiting for connection...
      </span>

      <span :if={@connected?}>
        <.icon name="ri-check-line" class="h-3.5 w-3.5 mr-1" /> Connected, click to continue
      </span>
    </.link>
    """
  end

  @doc """
  Renders verification timestamp
  """
  attr :schema, :any, required: true

  def verified(%{schema: %{verified_at: nil}} = assigns) do
    ~H"""
    Not Verified
    """
  end

  def verified(%{schema: %{verified_at: _verified_at}} = assigns) do
    ~H"""
    <div class="flex items-center gap-x-1">
      <.icon name="ri-shield-check-line" class="w-4 h-4" /> Verified
      <.relative_datetime datetime={@schema.verified_at} />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true

  def actor_link(%{actor: %Portal.Actor{type: :api_client}} = assigns) do
    ~H"""
    <.link class={link_style()} navigate={~p"/#{@account}/settings/api_clients"}>
      {assigns.actor.name}
    </.link>
    """
  end

  def actor_link(assigns) do
    ~H"""
    <.link class={link_style()} navigate={~p"/#{@account}/actors/#{@actor}"}>
      {assigns.actor.name}
    </.link>
    """
  end

  @doc """
  Renders a group as a badge with optional directory icon.
  Used in contexts like policies list where we need a compact badge representation.

  When group is nil (orphaned policy), displays a warning badge indicating the group is unavailable.
  """
  attr :account, :any, required: true
  attr :group, :any, default: nil
  attr :class, :string, default: nil
  attr :return_to, :string, default: nil

  def group_badge(%{group: nil} = assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-sm border border-primary-300 bg-primary-50 overflow-hidden mr-1",
      @class
    ]}>
      <span class="inline-flex items-center justify-center py-0.5 px-1.5 text-primary-600 bg-primary-100 border-r border-primary-300">
        <.icon name="ri-error-warning-line" class="h-3.5 w-3.5" />
      </span>
      <span class="text-xs truncate min-w-0 py-0.5 pl-1.5 pr-2.5 text-primary-700">
        Group deleted
      </span>
    </span>
    """
  end

  def group_badge(assigns) do
    # Build the navigate URL with return_to if provided
    assigns =
      if assigns[:return_to] do
        assign(
          assigns,
          :navigate_url,
          ~p"/#{assigns.account}/groups/#{assigns.group}?#{[return_to: assigns.return_to]}"
        )
      else
        assign(assigns, :navigate_url, ~p"/#{assigns.account}/groups/#{assigns.group}")
      end

    ~H"""
    <span
      class={[
        "inline-flex items-center rounded-sm border border-neutral-200 overflow-hidden mr-1",
        @class
      ]}
      data-group-id={@group.id}
    >
      <span class={~w[
          inline-flex items-center justify-center
          py-0.5 px-1.5
          text-neutral-800
          bg-neutral-100
          border-r
          border-neutral-200
        ]}>
        <.provider_icon provider={provider_type_from_group(@group)} size="xs" />
      </span>
      <.link
        title={"View Group \"#{@group.name}\""}
        navigate={@navigate_url}
        class="text-xs truncate min-w-0 py-0.5 pl-1.5 pr-2.5 text-neutral-900 bg-neutral-50"
      >
        {@group.name}
      </.link>
    </span>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :class, :string, default: nil
  attr :return_to, :string, default: nil

  def group(assigns) do
    # Build the navigate URL with return_to if provided
    assigns =
      if assigns[:return_to] do
        assign(
          assigns,
          :navigate_url,
          ~p"/#{assigns.account}/groups/#{assigns.group}?#{[return_to: assigns.return_to]}"
        )
      else
        assign(assigns, :navigate_url, ~p"/#{assigns.account}/groups/#{assigns.group}")
      end

    ~H"""
    <span class={["flex items-center", @class]} data-group-id={@group.id}>
      <span :if={@group.idp_id} class={~w[
          inline-flex items-center justify-center
          rounded-l
          py-0.5 px-1.5
          text-neutral-800
          bg-neutral-100
          border-neutral-100
          border
        ]}>
        <.provider_icon provider={provider_type_from_group(@group)} size="xs" />
      </span>
      <.link
        title={"View Group \"#{@group.name}\""}
        navigate={@navigate_url}
        class={[
          "text-xs truncate min-w-0 py-0.5 text-neutral-900 bg-neutral-50",
          if(@group.idp_id, do: "rounded-r pl-1.5 pr-2.5", else: "rounded-sm px-2.5")
        ]}
      >
        {@group.name}
      </.link>
    </span>
    """
  end

  @doc """

  """
  attr :schema, :any, required: true

  def last_seen(assigns) do
    assigns = assign_last_seen_fields(assigns)

    ~H"""
    <%= if @schema do %>
      <span class="inline-block">
        {@display_remote_ip}
      </span>
      <span class="inline-block">
        {[
          @display_remote_ip_location_city,
          Portal.Geo.country_common_name!(@display_remote_ip_location_region)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")}

        <a
          :if={
            not is_nil(@display_remote_ip_location_lat) and
              not is_nil(@display_remote_ip_location_lon)
          }
          aria-label="Open remote IP location in Google Maps"
          class="inline-flex align-middle text-current hover:text-heading transition-colors"
          target="_blank"
          title="Open remote IP location in Google Maps"
          rel="noopener noreferrer"
          href={"https://www.google.com/maps/place/#{@display_remote_ip_location_lat},#{@display_remote_ip_location_lon}"}
        >
          <.icon name="ri-external-link-line" class="ml-1 w-3 h-3" />
        </a>
      </span>
    <% else %>
      <span class="inline-block">-</span>
    <% end %>
    """
  end

  defp assign_last_seen_fields(%{schema: nil} = assigns), do: assigns

  defp assign_last_seen_fields(%{schema: %Portal.ClientSession{} = s} = assigns) do
    assigns
    |> assign(:display_remote_ip, s.remote_ip)
    |> assign(:display_remote_ip_location_city, s.remote_ip_location_city)
    |> assign(:display_remote_ip_location_region, s.remote_ip_location_region)
    |> assign(:display_remote_ip_location_lat, s.remote_ip_location_lat)
    |> assign(:display_remote_ip_location_lon, s.remote_ip_location_lon)
  end

  defp assign_last_seen_fields(%{schema: %Portal.GatewaySession{} = s} = assigns) do
    assigns
    |> assign(:display_remote_ip, s.remote_ip)
    |> assign(:display_remote_ip_location_city, s.remote_ip_location_city)
    |> assign(:display_remote_ip_location_region, s.remote_ip_location_region)
    |> assign(:display_remote_ip_location_lat, s.remote_ip_location_lat)
    |> assign(:display_remote_ip_location_lon, s.remote_ip_location_lon)
  end

  defp assign_last_seen_fields(%{schema: s} = assigns) do
    assigns
    |> assign(:display_remote_ip, s.last_seen_remote_ip)
    |> assign(:display_remote_ip_location_city, s.last_seen_remote_ip_location_city)
    |> assign(:display_remote_ip_location_region, s.last_seen_remote_ip_location_region)
    |> assign(:display_remote_ip_location_lat, s.last_seen_remote_ip_location_lat)
    |> assign(:display_remote_ip_location_lon, s.last_seen_remote_ip_location_lon)
  end

  @doc """
  Helps to pluralize a word based on a cardinal number.

  Cardinal numbers indicate an amount—how many of something we have: one, two, three, four, five.

  Typically for English you want to set `one` and `other` options. The `other` option is used for all
  other numbers that are not `one`. For example, if you want to pluralize the word "file" you would
  set `one` to "file" and `other` to "files".
  """
  attr :number, :integer, required: true

  attr :zero, :string, required: false
  attr :one, :string, required: false
  attr :two, :string, required: false
  attr :few, :string, required: false
  attr :many, :string, required: false
  attr :other, :string, required: true

  attr :rest, :global

  def cardinal_number(assigns) do
    opts = Map.take(assigns, [:zero, :one, :two, :few, :many, :other])
    assigns = Map.put(assigns, :opts, opts)

    ~H"""
    <span data-value={@number} {@rest}>
      {PortalWeb.Format.cardinal_pluralize(@number, @opts)}
    </span>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(PortalWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(PortalWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) or is_map(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  def translate_errors(errors, _field) when is_nil(errors) do
    []
  end

  @doc """
  This component is meant to be used for step by step instructions

  ex.
  <.step>
    <:title>Step 1. Do Something</:title>
    <:content>
      Here are instructions for step 1...
    </:content>
  </.step>

  <.step>
    <:title>Step 2. Do Another Thing</:title>
    <:content>
      Here are instructions for step 2...
    </:content>
  </.step>

  """
  slot :title, required: true
  slot :content, required: true

  def step(assigns) do
    ~H"""
    <div class="mb-6">
      <h2 class="mb-2 text-2xl tracking-tight font-medium text-neutral-900">
        {render_slot(@title)}
      </h2>
      <div class="px-4">
        {render_slot(@content)}
      </div>
    </div>
    """
  end

  @doc """
  Render an animated status indicator dot.
  """

  attr :color, :string, default: "info"
  attr :title, :string, default: nil
  attr :class, :string, default: nil

  def ping_icon(assigns) do
    ~H"""
    <span class={["relative flex h-2.5 w-2.5", @class]} title={@title}>
      <span class={~w[
        animate-ping absolute inline-flex
        h-full w-full rounded-full opacity-50
        #{ping_icon_color(@color) |> elem(1)}]}></span>
      <span class={~w[
        relative inline-flex rounded-full h-2.5 w-2.5
        #{ping_icon_color(@color) |> elem(0)}]}></span>
    </span>
    """
  end

  defp ping_icon_color(color) do
    case color do
      "info" -> {"bg-accent-500", "bg-accent-400"}
      "success" -> {"bg-success", "bg-green-400"}
      "warning" -> {"bg-warning", "bg-amber-400"}
      "danger" -> {"bg-danger", "bg-red-400"}
    end
  end

  @doc """
  Helper function to get provider type from group.
  Groups have a directory_type field that indicates the provider.
  If the group has idp_id but no directory_type, it's synced but we can't determine the provider.
  """
  def provider_type_from_group(%{directory_type: type}) when not is_nil(type), do: to_string(type)

  def provider_type_from_group(%{directory: %{type: type}}) when not is_nil(type),
    do: to_string(type)

  def provider_type_from_group(%{idp_id: idp_id}) when not is_nil(idp_id), do: "unknown"
  def provider_type_from_group(_), do: "firezone"

  @doc """
  Helper function to get provider type from an issuer URL.
  """
  def provider_type_from_issuer(issuer) when is_binary(issuer) do
    cond do
      String.contains?(issuer, "okta.com") -> "okta"
      String.contains?(issuer, "google.com") -> "google"
      String.contains?(issuer, "microsoftonline.com") -> "entra"
      true -> "oidc"
    end
  end

  def provider_type_from_issuer(_), do: "firezone"

  @doc """
  Renders a logo appropriate for the given provider.

  <.provider_icon provider="google" size="md" />
  <.provider_icon provider="okta" size="xl" variant="circle" />
  <.provider_icon provider={@type} size="sm" />
  """
  attr :provider, :string, required: true

  attr :size, :string, default: "md", values: ~w[xs sm md lg xl]
  attr :variant, :string, default: "plain", values: ~w[plain circle square]
  attr :rest, :global

  def provider_icon(assigns) do
    assigns =
      assigns
      |> assign(:icon_spec, provider_icon_spec(assigns.provider))
      |> assign(:icon_class, provider_icon_size(assigns.size))
      |> assign(:wrapper_class, provider_icon_variant(assigns.variant, assigns.size))

    ~H"""
    <span class={["shrink-0", @wrapper_class]} {@rest}>
      <%= if @icon_spec.type == :image && Map.has_key?(@icon_spec, :dark_src) do %>
        <img
          src={@icon_spec.src}
          alt={@icon_spec.alt}
          class={[@icon_class, "dark:hidden"]}
        />

        <img
          src={@icon_spec.dark_src}
          alt={@icon_spec.alt}
          class={[@icon_class, "hidden dark:block"]}
        />
      <% else %>
        <img
          :if={@icon_spec.type == :image}
          src={@icon_spec.src}
          alt={@icon_spec.alt}
          class={@icon_class}
        />
      <% end %>
      <.icon
        :if={@icon_spec.type == :icon}
        name={@icon_spec.name}
        class={[@icon_class, "text-[var(--text-primary)]"]}
        aria-hidden="true"
      />
    </span>
    """
  end

  defp provider_icon_spec("firezone") do
    %{
      type: :image,
      src: ~p"/images/logo.svg",
      alt: "Firezone"
    }
  end

  defp provider_icon_spec("google") do
    %{
      type: :image,
      src: ~p"/images/logo-google.svg",
      alt: "Google"
    }
  end

  defp provider_icon_spec("entra") do
    %{
      type: :image,
      src: ~p"/images/logo-entra.svg",
      alt: "Microsoft Entra"
    }
  end

  defp provider_icon_spec("okta") do
    %{
      type: :image,
      src: ~p"/images/logo-okta.svg",
      dark_src: ~p"/images/logo-okta-dark.svg",
      alt: "Okta"
    }
  end

  defp provider_icon_spec("oidc") do
    %{
      type: :image,
      src: ~p"/images/logo-openid.svg",
      alt: "OpenID Connect"
    }
  end

  defp provider_icon_spec("email_otp") do
    %{
      type: :icon,
      name: "ri-mail-line"
    }
  end

  defp provider_icon_spec("userpass") do
    %{
      type: :icon,
      name: "ri-key-line"
    }
  end

  defp provider_icon_spec(_unknown) do
    %{
      type: :icon,
      name: "ri-question-line"
    }
  end

  defp provider_icon_size("xs"), do: "size-3"
  defp provider_icon_size("sm"), do: "size-4"
  defp provider_icon_size("md"), do: "size-5"
  defp provider_icon_size("lg"), do: "size-6"
  defp provider_icon_size("xl"), do: "size-8"

  defp provider_icon_variant("plain", _size), do: nil

  defp provider_icon_variant("circle", size) do
    [
      "inline-flex items-center justify-center rounded-full bg-[var(--icon-bg)] border border-[var(--border)]",
      provider_icon_wrapper_size(size)
    ]
  end

  defp provider_icon_variant("square", size) do
    [
      "inline-flex items-center justify-center rounded-md bg-[var(--icon-bg)] border border-[var(--border)]",
      provider_icon_wrapper_size(size)
    ]
  end

  defp provider_icon_wrapper_size("xs"), do: "size-5"
  defp provider_icon_wrapper_size("sm"), do: "size-7"
  defp provider_icon_wrapper_size("md"), do: "size-8"
  defp provider_icon_wrapper_size("lg"), do: "size-10"
  defp provider_icon_wrapper_size("xl"), do: "size-12"

  def feature_name(%{feature: :idp_sync} = assigns) do
    ~H"""
    Automatically sync users and groups
    """
  end

  def feature_name(%{feature: :policy_conditions} = assigns) do
    ~H"""
    Specify access-time conditions when creating policies
    """
  end

  def feature_name(%{feature: :traffic_filters} = assigns) do
    ~H"""
    Restrict access based on port and protocol rules
    """
  end

  def feature_name(%{feature: :rest_api} = assigns) do
    ~H"""
    REST API
    """
  end

  def feature_name(assigns) do
    ~H""
  end

  def mailto_support(account, subject, email_subject) do
    body =
      """


      ---
      Please do not remove this part of the email.
      Account Name: #{account.name}
      Account Slug: #{account.slug}
      Account ID: #{account.id}
      Actor ID: #{subject.actor.id}
      """

    "mailto:support@firezone.dev?subject=#{URI.encode_www_form(email_subject)}&body=#{URI.encode_www_form(body)}"
  end

  def link_style do
    [
      "text-accent-500",
      "hover:underline"
    ]
  end

  @doc """
  Renders a Flowbite-style toggle switch.

  ## Examples

      <.toggle
        id="my-toggle"
        checked={@is_enabled}
        phx-click="toggle_enabled"
        phx-value-id={@id}
      />

      <.toggle
        id="my-toggle"
        checked={@is_enabled}
        label="Enable feature"
        phx-click="toggle_enabled"
      />
  """
  attr :id, :string, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :name, :string, default: nil
  attr :value, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <label class={["inline-flex items-center cursor-pointer", @class]}>
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        disabled={@disabled}
        class="sr-only peer"
        {@rest}
      />
      <div class={[
        "relative w-11 h-6 bg-gray-200 rounded-full peer",
        "peer-focus:outline-hidden peer-focus:ring-4 peer-focus:ring-accent-300",
        "peer-checked:after:translate-x-full rtl:peer-checked:after:-translate-x-full",
        "peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px]",
        "after:start-[2px] after:bg-white after:border-neutral-300 after:border",
        "after:rounded-full after:h-5 after:w-5 after:transition-all",
        "peer-checked:bg-accent-600",
        @disabled && "opacity-50 cursor-not-allowed"
      ]}>
      </div>
      <span :if={@label} class="ms-3 text-sm font-medium text-gray-900">
        {@label}
      </span>
    </label>
    """
  end

  @doc """
  Renders a status badge pill.

  ## Statuses

  - `:success` — green
  - `:warning` — amber
  - `:danger` — red
  - `:neutral` — gray

  ## Examples

    <.status_badge style={:success}>Online</.status_badge>
    <.status_badge style={:neutral}>Offline</.status_badge>
    <.status_badge style={:warning}>Degraded</.status_badge>
    <.status_badge style={:danger}>Disabled</.status_badge>
    <.status_badge style={:success} dot={false}>Active</.status_badge>
  """
  attr :style, :atom, required: true, values: [:success, :warning, :danger, :neutral]
  attr :dot, :boolean, default: true
  slot :inner_block, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[11px] font-medium",
      badge_pill_class(@style)
    ]}>
      <span :if={@dot} class={["w-1.5 h-1.5 rounded-full shrink-0", badge_dot_class(@style)]}></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_pill_class(:success), do: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400"
  defp badge_pill_class(:warning), do: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400"
  defp badge_pill_class(:danger), do: "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400"
  defp badge_pill_class(:neutral), do: "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"

  defp badge_dot_class(:success), do: "bg-green-500"
  defp badge_dot_class(:warning), do: "bg-amber-500"
  defp badge_dot_class(:danger), do: "bg-red-500"
  defp badge_dot_class(:neutral), do: "bg-gray-400"
end
