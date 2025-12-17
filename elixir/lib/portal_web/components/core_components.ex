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

  @doc """
  Renders a generic <p> tag using our color scheme.

  ## Examples

    <.p>
      Hello world
    </.p>
  """
  def p(assigns) do
    ~H"""
    <p class="text-neutral-700">{render_slot(@inner_block)}</p>
    """
  end

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
        "#{assigns.class} font-semibold p-[0.15rem] bg-neutral-100 rounded"
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
          rounded py-2 px-2.5 inline-flex items-center justify-center
          bg-white border-gray-200 border h-8
        ]}
      >
        <span id={"#{@id}-default-message"} class="inline-flex items-center">
          <span class="inline-flex items-center">
            <.icon name="hero-clipboard" data-icon class="h-4 w-4 me-1.5" />
            <span class="text-xs font-semibold">Copy</span>
          </span>
        </span>
        <span id={"#{@id}-success-message"} class="inline-flex items-center hidden">
          <span class="inline-flex items-center">
            <.icon name="hero-check" data-icon class="text-green-700 h-4 w-4 me-1.5" />
            <span class="text-xs font-semibold text-green-700">Copied</span>
          </span>
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
        <.icon name="hero-clipboard-document" data-icon class="h-4 w-4" />
      </button>
    </div>
    """
  end

  @doc """
  Render a tabs toggle container and its content.

  ## Examples

  <.tabs id={"hello-world"}>
    <:tab id={"hello"} label={"Hello"}>
      <p>Hello</p>
    </:tab>
    <:tab id={"world"} label={"World"}>
      <p>World</p>
    </:tab>
  </.tabs>
  """

  attr :id, :string, required: true, doc: "ID of the tabs container"

  slot :tab, required: true, doc: "Tab content" do
    attr :id, :string, required: true, doc: "ID of the tab"
    attr :label, :any, required: true, doc: "Display label for the tab"
    attr :icon, :string, doc: "Icon for the tab"
    attr :selected, :boolean, doc: "Whether the tab is selected"
    attr :phx_click, :any, doc: "Phoenix click event"
  end

  attr :rest, :global

  def tabs(assigns) do
    ~H"""
    <div class="mb-4 rounded shadow">
      <div
        class="border-neutral-100 border-b-2 bg-neutral-50 rounded-t"
        id={"#{@id}-container"}
        phx-hook="Tabs"
        {@rest}
      >
        <ul
          class="flex flex-wrap text-sm text-center"
          id={"#{@id}-ul"}
          data-tabs-toggle={"##{@id}"}
          role="tablist"
        >
          <%= for tab <- @tab do %>
            <% tab = Map.put(tab, :icon, Map.get(tab, :icon, nil)) %>
            <li class="mr-2" role="presentation">
              <button
                class={
                  [
                    # ! is needed to override Flowbite's default styles
                    (Map.get(tab, :selected) &&
                       "!rounded-t-lg !font-medium !text-accent-600 !border-accent-600") ||
                      "!text-neutral-500 !hover:border-accent-700 !hover:text-accent-600",
                    "inline-block p-4 border-b-2"
                  ]
                }
                id={"#{tab.id}-tab"}
                data-tabs-target={"##{tab.id}"}
                type="button"
                role="tab"
                aria-controls={tab.id}
                aria-selected={(Map.get(tab, :selected) && "true") || "false"}
                phx-click={Map.get(tab, :phx_click)}
                phx-value-id={tab.id}
              >
                <span class="flex items-center">
                  <%= if tab.icon do %>
                    <.icon name={tab.icon} class="h-4 w-4 mr-2" />
                  <% end %>
                  {tab.label}
                </span>
              </button>
            </li>
          <% end %>
        </ul>
      </div>
      <div id={@id}>
        <%= for tab <- @tab do %>
          <div
            class="hidden rounded-b bg-white"
            id={tab.id}
            role="tabpanel"
            aria-labelledby={"#{tab.id}-tab"}
          >
            {render_slot(tab)}
          </div>
        <% end %>
      </div>
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
    <div class="py-6 px-1">
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
        @base_kind == :success && "text-green-800 bg-green-100 border-green-300",
        @base_kind == :info && "text-blue-800 bg-blue-100 border-blue-300",
        @base_kind == :warning && "text-yellow-800 bg-yellow-100 border-yellow-300",
        @base_kind == :error && "text-red-800 bg-red-100 border-red-300",
        @style == "toast" && "m-0 border rounded shadow-lg",
        @style == "inline" && "mb-4 rounded border",
        @class
      ]}
      role="alert"
      phx-hook={if @style == "toast", do: "Toast", else: nil}
      data-autoshow={if @style == "toast", do: to_string(@autoshow), else: nil}
      {@rest}
    >
      <div class={[@style == "toast" && "flex items-start gap-3"]}>
        <div class="flex-1">
          <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6 mb-1">
            <.icon :if={@base_kind == :info} name="hero-information-circle" class="h-4 w-4" />
            <.icon :if={@base_kind == :success} name="hero-check-circle" class="h-4 w-4" />
            <.icon :if={@base_kind == :warning} name="hero-exclamation-triangle" class="h-4 w-4" />
            <.icon :if={@base_kind == :error} name="hero-exclamation-circle" class="h-4 w-4" />
            {@title}
          </p>
          {maybe_render_changeset_as_flash(msg)}
        </div>
        <button
          :if={@style == "toast"}
          type="button"
          class="text-current opacity-50 hover:opacity-100 flex-shrink-0"
          popovertarget={@id}
          popovertargetaction="hide"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="h-4 w-4" />
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
    <label for={@for} class={["block text-sm text-neutral-900 mb-2", @class]}>
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
        "text-rose-600",
        (@inline && "ml-2") || "mt-2 w-full",
        @class
      ]}
      {@rest}
    >
      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4 flex-none" />
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
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
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
  Renders a [Hero Icon](https://heroicons.com).

  Hero icons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from your `assets/vendor/heroicons` directory and bundled
  within your compiled app.css by the plugin in your `assets/tailwind.config.js`.

  ## Examples

      <.icon name="hero-x-mark-solid" />
      <.icon name="hero-arrow-path" class="ml-1 w-3 h-3 animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  def icon(%{name: "firezone"} = assigns) do
    ~H"""
    <img src={~p"/images/logo.svg"} class={["inline-block", @class]} {@rest} />
    """
  end

  def icon(%{name: "spinner"} = assigns) do
    ~H"""
    <svg
      class={["inline-block", @class]}
      xmlns="http://www.w3.org/2000/svg"
      fill="none"
      viewBox="0 0 24 24"
      {@rest}
    >
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
      </circle>
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      >
      </path>
    </svg>
    """
  end

  def icon(%{name: "terraform"} = assigns) do
    ~H"""
    <span class={"inline-flex " <> @class} @rest>
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
        <g fill-rule="evenodd">
          <path d="M77.941 44.5v36.836L46.324 62.918V26.082zm0 0" fill="currentColor" />
          <path d="M81.41 81.336l31.633-18.418V26.082L81.41 44.5zm0 0" fill="currentColor" />
          <path
            d="M11.242 42.36L42.86 60.776V23.941L11.242 5.523zm0 0M77.941 85.375L46.324 66.957v36.82l31.617 18.418zm0 0"
            fill="currentColor"
          />
        </g>
      </svg>
    </span>
    """
  end

  def icon(%{name: "docker"} = assigns) do
    ~H"""
    <span class={"inline-flex " <> @class} @rest>
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 756.26 596.9">
        <defs>
          <style>
            .cls-1 {
              stroke-width: 0px;
            }
          </style>
        </defs>
        <path
          fill="currentColor"
          class="cls-1"
          d="M743.96,245.25c-18.54-12.48-67.26-17.81-102.68-8.27-1.91-35.28-20.1-65.01-53.38-90.95l-12.32-8.27-8.21,12.4c-16.14,24.5-22.94,57.14-20.53,86.81,1.9,18.28,8.26,38.83,20.53,53.74-46.1,26.74-88.59,20.67-276.77,20.67H.06c-.85,42.49,5.98,124.23,57.96,190.77,5.74,7.35,12.04,14.46,18.87,21.31,42.26,42.32,106.11,73.35,201.59,73.44,145.66.13,270.46-78.6,346.37-268.97,24.98.41,90.92,4.48,123.19-57.88.79-1.05,8.21-16.54,8.21-16.54l-12.3-8.27ZM189.67,206.39h-81.7v81.7h81.7v-81.7ZM295.22,206.39h-81.7v81.7h81.7v-81.7ZM400.77,206.39h-81.7v81.7h81.7v-81.7ZM506.32,206.39h-81.7v81.7h81.7v-81.7ZM84.12,206.39H2.42v81.7h81.7v-81.7ZM189.67,103.2h-81.7v81.7h81.7v-81.7ZM295.22,103.2h-81.7v81.7h81.7v-81.7ZM400.77,103.2h-81.7v81.7h81.7v-81.7ZM400.77,0h-81.7v81.7h81.7V0Z"
        />
      </svg>
    </span>
    """
  end

  def icon(%{name: "os-android"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 50 50"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Android</title>
      <path
        style="fill:currentColor;stroke:currentColor;stroke-width:0.8"
        d="M 16.375 -0.03125 C 16.332031 -0.0234375 16.289063 -0.0117188 16.25 0 C 15.921875 0.0742188 15.652344 0.304688 15.53125 0.621094 C 15.410156 0.9375 15.457031 1.289063 15.65625 1.5625 L 17.78125 4.75 C 14.183594 6.640625 11.601563 9.902344 11 13.78125 C 11 13.792969 11 13.800781 11 13.8125 C 11 13.824219 11 13.832031 11 13.84375 C 11 13.875 11 13.90625 11 13.9375 C 11 13.957031 11 13.980469 11 14 C 10.996094 14.050781 10.996094 14.105469 11 14.15625 L 11 15.5625 C 10.40625 15.214844 9.734375 15 9 15 C 6.800781 15 5 16.800781 5 19 L 5 31 C 5 33.199219 6.800781 35 9 35 C 9.734375 35 10.40625 34.785156 11 34.4375 L 11 37 C 11 38.644531 12.355469 40 14 40 L 15 40 L 15 46 C 15 48.199219 16.800781 50 19 50 C 21.199219 50 23 48.199219 23 46 L 23 40 L 27 40 L 27 46 C 27 48.199219 28.800781 50 31 50 C 33.199219 50 35 48.199219 35 46 L 35 40 L 36 40 C 37.644531 40 39 38.644531 39 37 L 39 34.4375 C 39.59375 34.785156 40.265625 35 41 35 C 43.199219 35 45 33.199219 45 31 L 45 19 C 45 16.800781 43.199219 15 41 15 C 40.265625 15 39.59375 15.214844 39 15.5625 L 39 14.1875 C 39.011719 14.09375 39.011719 14 39 13.90625 C 39 13.894531 39 13.886719 39 13.875 C 39 13.863281 39 13.855469 39 13.84375 C 38.417969 9.9375 35.835938 6.648438 32.21875 4.75 L 34.34375 1.5625 C 34.589844 1.226563 34.597656 0.773438 34.367188 0.425781 C 34.140625 0.078125 33.71875 -0.09375 33.3125 0 C 33.054688 0.0585938 32.828125 0.214844 32.6875 0.4375 L 30.34375 3.90625 C 28.695313 3.3125 26.882813 3 25 3 C 23.117188 3 21.304688 3.3125 19.65625 3.90625 L 17.3125 0.4375 C 17.113281 0.117188 16.75 -0.0625 16.375 -0.03125 Z M 25 5 C 26.878906 5 28.640625 5.367188 30.1875 6.03125 C 30.21875 6.042969 30.25 6.054688 30.28125 6.0625 C 33.410156 7.433594 35.6875 10 36.5625 13 L 13.4375 13 C 14.300781 10.042969 16.53125 7.507813 19.59375 6.125 C 19.660156 6.101563 19.722656 6.070313 19.78125 6.03125 C 21.335938 5.359375 23.109375 5 25 5 Z M 19.5 8 C 18.667969 8 18 8.671875 18 9.5 C 18 10.332031 18.667969 11 19.5 11 C 20.328125 11 21 10.332031 21 9.5 C 21 8.671875 20.328125 8 19.5 8 Z M 30.5 8 C 29.671875 8 29 8.671875 29 9.5 C 29 10.332031 29.671875 11 30.5 11 C 31.332031 11 32 10.332031 32 9.5 C 32 8.671875 31.332031 8 30.5 8 Z M 13 15 L 37 15 L 37 37 C 37 37.5625 36.5625 38 36 38 L 28.1875 38 C 28.054688 37.972656 27.914063 37.972656 27.78125 38 L 16.1875 38 C 16.054688 37.972656 15.914063 37.972656 15.78125 38 L 14 38 C 13.4375 38 13 37.5625 13 37 Z M 9 17 C 10.117188 17 11 17.882813 11 19 L 11 31 C 11 32.117188 10.117188 33 9 33 C 7.882813 33 7 32.117188 7 31 L 7 19 C 7 17.882813 7.882813 17 9 17 Z M 41 17 C 42.117188 17 43 17.882813 43 19 L 43 31 C 43 32.117188 42.117188 33 41 33 C 39.882813 33 39 32.117188 39 31 L 39 19 C 39 17.882813 39.882813 17 41 17 Z M 17 40 L 21 40 L 21 46 C 21 47.117188 20.117188 48 19 48 C 17.882813 48 17 47.117188 17 46 Z M 29 40 L 33 40 L 33 46 C 33 47.117188 32.117188 48 31 48 C 29.882813 48 29 47.117188 29 46 Z"
      />
    </svg>
    """
  end

  def icon(%{name: "os-ios"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 50 50"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Apple iOS</title>
      <path
        style="fill:currentColor;stroke:currentColor;"
        d="M 15 3 C 8.3845336 3 3 8.3845336 3 15 L 3 35 C 3 41.615466 8.3845336 47 15 47 L 35 47 C 41.615466 47 47 41.615466 47 35 L 47 15 C 47 8.3845336 41.615466 3 35 3 L 15 3 z M 15 5 L 35 5 C 40.534534 5 45 9.4654664 45 15 L 45 35 C 45 40.534534 40.534534 45 35 45 L 15 45 C 9.4654664 45 5 40.534534 5 35 L 5 15 C 5 9.4654664 9.4654664 5 15 5 z M 11.615234 18.066406 C 10.912234 18.066406 10.394531 18.567563 10.394531 19.226562 C 10.394531 19.876563 10.912234 20.376953 11.615234 20.376953 C 12.318234 20.376953 12.837891 19.876562 12.837891 19.226562 C 12.837891 18.567562 12.318234 18.066406 11.615234 18.066406 z M 22.037109 18.636719 C 18.398109 18.636719 16.113281 21.18525 16.113281 25.28125 C 16.113281 29.36825 18.354109 31.933594 22.037109 31.933594 C 25.711109 31.933594 27.943359 29.35925 27.943359 25.28125 C 27.943359 21.19425 25.693109 18.637719 22.037109 18.636719 z M 34.966797 18.636719 C 32.198797 18.636719 30.351562 20.139437 30.351562 22.398438 C 30.351562 24.261437 31.397406 25.37025 33.691406 25.90625 L 35.326172 26.302734 C 37.005172 26.697734 37.744141 27.277141 37.744141 28.244141 C 37.744141 29.369141 36.583953 30.185547 35.001953 30.185547 C 33.306858 30.185547 32.128927 29.421639 31.960938 28.21875 L 30.007812 28.21875 C 30.148813 30.48675 32.037609 31.935547 34.849609 31.935547 C 37.855609 31.935547 39.736328 30.416234 39.736328 27.990234 C 39.736328 26.083234 38.6645 25.027875 36.0625 24.421875 L 34.666016 24.078125 C 33.014016 23.691125 32.345703 23.172578 32.345703 22.267578 C 32.345703 21.124578 33.383453 20.378906 34.939453 20.378906 C 36.416453 20.378906 37.434141 21.106391 37.619141 22.275391 L 39.535156 22.275391 C 39.421156 20.139391 37.541797 18.636719 34.966797 18.636719 z M 22.037109 20.472656 C 24.446109 20.472656 25.931641 22.33725 25.931641 25.28125 C 25.931641 28.20725 24.445109 30.097656 22.037109 30.097656 C 19.603109 30.097656 18.126953 28.20825 18.126953 25.28125 C 18.126953 22.33725 19.646109 20.473656 22.037109 20.472656 z M 10.675781 22.056641 L 10.675781 31.626953 L 12.556641 31.626953 L 12.556641 22.056641 L 10.675781 22.056641 z"
      />
    </svg>
    """
  end

  def icon(%{name: "os-macos"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      aria-label="macOS"
      viewBox="0 0 512 512"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Apple MacOS</title>
      <path
        style="fill:currentColor;stroke:currentColor;stroke-width:1.52252"
        d="m 299.13901,115.41591 v -6.09009 c -79.17109,0 -7.61261,51.76572 0,6.09009 z m 36.54051,-27.40538 c 10.65764,-31.97294 65.46839,-35.017982 71.55848,4.567562 h -15.22521 c -4.56756,-22.837814 -42.63058,-24.360335 -42.63058,16.747728 0,22.83782 35.01797,36.54051 42.63058,9.13513 H 407.238 c -9.13512,50.24319 -89.82873,31.97294 -71.55848,-30.45042 z M 113.39145,63.650194 h 15.22522 v 13.702689 c 7.6126,-18.270251 41.10806,-19.792772 47.19815,1.522521 10.65764,-22.837814 53.28822,-21.315293 53.28822,10.657647 V 145.86633 H 212.35531 V 94.100613 c 0,-22.837814 -33.49545,-22.837814 -33.49545,1.522521 V 145.86633 H 162.11213 V 92.578092 C 158.38652,78.327296 139.40372,75.480182 131.66171,88.01053 l -3.04504,7.612604 v 50.243196 h -15.22522 z m 35.01799,394.332936 c -71.558493,0 -115.711601,-50.2432 -115.711601,-130.93681 0,-80.6936 44.153108,-129.41428 115.711601,-129.41428 71.55848,0 117.23411,50.24319 117.23411,129.41428 0,79.17109 -44.15311,130.93681 -117.23411,130.93681 z m 133.98184,-312.1168 c -44.1531,10.65764 -50.24319,-45.67563 -4.56756,-47.198154 l 21.31529,-1.522521 V 91.055572 C 300.66154,72.78532 270.21112,71.262799 265.64355,88.01053 h -15.22521 a 21.315293,21.315293 0 0 1 3.04505,-10.657647 C 265.64355,56.03759 315.88675,56.03759 315.88675,89.533051 v 56.333279 h -15.22521 v -13.70269 a 27.405377,27.405377 0 0 1 -18.27026,13.70269 z m 103.53143,312.1168 c -54.81075,-3.04505 -92.87378,-28.9279 -95.91883,-74.60353 h 36.54051 c 35.01798,109.62151 222.28806,-7.61261 38.06303,-45.67563 -28.9279,-6.09008 -50.2432,-19.79277 -59.37833,-36.5405 C 247.3733,188.49691 471.18388,155.00145 477.27396,270.71305 h -35.01797 c -10.65766,-74.60353 -149.20706,-33.49547 -98.96387,18.27025 21.3153,21.31529 65.4684,19.79278 97.44135,33.49546 76.12604,35.01798 39.58554,138.54941 -54.81076,135.50437 z M 148.40944,229.60499 c -48.720679,0 -79.171099,38.06301 -79.171099,97.44133 0,59.37833 30.45042,97.44134 79.171099,97.44134 48.72066,0 80.6936,-36.5405 80.6936,-97.44134 0,-60.90084 -30.45041,-97.44133 -80.6936,-97.44133 z"
      />
    </svg>
    """
  end

  def icon(%{name: "os-windows"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Windows</title>
      <polygon
        points="12.5 10.5 22.5 10.5 22.5 1.5 12.5 2.69 12.5 10.5"
        style="fill:none;stroke:currentColor;stroke-linecap:round;stroke-linejoin:round;stroke-width:1.52252"
      />
      <polygon
        points="9.5 10.5 9.5 3.05 1.5 4 1.5 10.5 9.5 10.5"
        style="fill:none;stroke:currentColor;stroke-linecap:round;stroke-linejoin:round;stroke-width:1.52252"
      />
      <polygon
        points="9.5 13.5 1.5 13.5 1.5 20 9.5 20.95 9.5 13.5"
        style="fill:none;stroke:currentColor;stroke-linecap:round;stroke-linejoin:round;stroke-width:1.52252"
      />
      <polygon
        points="12.5 13.5 12.5 21.31 22.5 22.5 22.5 13.5 12.5 13.5"
        style="fill:none;stroke:currentColor;stroke-linecap:round;stroke-linejoin:round;stroke-width:1.52252"
      />
    </svg>
    """
  end

  def icon(%{name: "os-ubuntu"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="-5 0 32 32"
      version="1.1"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Ubuntu</title>
      <path
        style="fill:currentColor;stroke:currentColor;"
        d="M16.469 9.375c-1.063-0.594-1.406-1.938-0.813-3 0.406-0.719 1.156-1.094 1.906-1.094 0.375 0 0.75 0.094 1.094 0.281 1.063 0.625 1.406 1.969 0.813 3-0.406 0.719-1.156 1.094-1.906 1.094-0.375 0-0.75-0.094-1.094-0.281zM21.938 15.594h-3.625c-0.125-1.688-0.969-3.188-2.25-4.156-0.219-0.156-0.438-0.313-0.688-0.469-0.813-0.438-1.75-0.688-2.75-0.688-1.031 0-1.969 0.25-2.813 0.719l-2-3.031c1.406-0.844 3.031-1.313 4.813-1.313 0.688 0 1.375 0.063 2.063 0.219-0.25 1.219 0.281 2.5 1.406 3.156 0.438 0.25 0.938 0.375 1.469 0.375 0.719 0 1.406-0.25 1.938-0.719 1.438 1.563 2.344 3.625 2.438 5.906zM7.125 8.438l2 3.031c-1.25 0.969-2.094 2.438-2.188 4.125-0.031 0.125-0.031 0.25-0.031 0.406 0 0.125 0 0.281 0.031 0.406 0.125 1.781 1.063 3.313 2.438 4.281l-1.906 3.094c-1.813-1.188-3.188-3-3.813-5.125 0.875-0.5 1.5-1.469 1.5-2.563s-0.625-2.094-1.563-2.594c0.594-2.063 1.844-3.844 3.531-5.063zM2.188 13.906c1.219 0 2.219 0.969 2.219 2.188s-1 2.219-2.219 2.219-2.188-1-2.188-2.219 0.969-2.188 2.188-2.188zM8.188 24.219l1.906-3.125c0.75 0.375 1.625 0.594 2.531 0.594 1 0 1.938-0.25 2.781-0.719 0.25-0.125 0.469-0.281 0.688-0.469 1.25-0.938 2.094-2.406 2.219-4.094h3.625c-0.094 2.375-1.094 4.531-2.656 6.125-0.469-0.344-1.063-0.531-1.656-0.531-0.531 0-1.031 0.125-1.469 0.375-1 0.594-1.531 1.656-1.469 2.719-0.688 0.156-1.375 0.25-2.063 0.25-1.625 0-3.125-0.406-4.438-1.125zM17.625 22.75c0.75 0 1.5 0.375 1.906 1.094 0.594 1.063 0.219 2.438-0.813 3.031-0.344 0.188-0.719 0.281-1.094 0.281-0.781 0-1.5-0.375-1.906-1.094-0.625-1.063-0.25-2.406 0.813-3.031 0.344-0.188 0.719-0.281 1.094-0.281z"
      />
    </svg>
    """
  end

  def icon(%{name: "os-debian"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      version="1.1"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Debian</title>
      <path
        style="fill:currentColor;stroke:currentColor;"
        d="M3.973 10.755c0.085-0.271 0.171-0.624 0.24-0.984l0.010-0.066c-0.437 0.55-0.212 0.662-0.25 1.037zM4.761 7.43c0.087 0.712-0.537 1 0.137 0.525 0.375-0.825-0.137-0.225-0.125-0.525zM16.562 1.154c0.327-0.062 0.734-0.115 1.146-0.147l0.041-0.003c-0.462 0.038-0.925 0.063-1.375 0.125l0.187 0.025zM27.378 14.53l-0.087 0.187c-0.145 1.031-0.448 1.963-0.885 2.814l0.023-0.049c0.472-0.854 0.803-1.852 0.933-2.912l0.004-0.040zM13.701 17.507c-0.153-0.187-0.283-0.401-0.381-0.633l-0.007-0.017c0.134 0.419 0.316 0.784 0.546 1.113l-0.009-0.013-0.15-0.45zM12.926 17.545l-0.062 0.35c0.298 0.477 0.628 0.89 1 1.262l-0-0c-0.3-0.587-0.525-0.825-0.937-1.625zM25.276 13.968c-0.028 0.687-0.2 1.328-0.487 1.901l0.012-0.027-0.437 0.226c-0.35 0.675 0.038 0.437-0.212 0.975-0.602 0.595-1.264 1.13-1.976 1.596l-0.048 0.030c-0.251 0 0.175-0.312 0.237-0.425-0.739 0.5-0.601 0.75-1.713 1.062l-0.038-0.075c-0.468 0.16-1.008 0.253-1.569 0.253-2.759 0-4.996-2.237-4.996-4.996 0-0.020 0-0.041 0-0.061l-0 0.003c-0.037 0.212-0.087 0.162-0.15 0.25-0.010-0.112-0.016-0.242-0.016-0.374 0-1.752 1.015-3.268 2.49-3.989l0.026-0.012c0.55-0.283 1.2-0.448 1.888-0.448 1.066 0 2.040 0.397 2.78 1.052l-0.004-0.004c-0.771-0.993-1.965-1.626-3.306-1.626-0.033 0-0.066 0-0.099 0.001l0.005-0c-1.417 0.013-2.649 0.792-3.303 1.943l-0.010 0.019c-0.75 0.475-0.837 1.837-1.162 2.076-0.068 0.337-0.107 0.724-0.107 1.12 0 2.225 1.232 4.161 3.051 5.165l0.030 0.015c0.337 0.237 0.1 0.262 0.15 0.437-0.752-0.362-1.388-0.85-1.906-1.443l-0.006-0.007c0.28 0.439 0.611 0.814 0.992 1.131l0.008 0.006c-0.687-0.225-1.587-1.625-1.849-1.687 1.162 2.074 4.724 3.65 6.574 2.874-0.164 0.012-0.355 0.019-0.547 0.019-0.845 0-1.658-0.135-2.419-0.385l0.055 0.016c-0.412-0.2-0.962-0.637-0.875-0.712 0.83 0.359 1.796 0.567 2.811 0.567 1.736 0 3.329-0.61 4.577-1.627l-0.013 0.010c0.55-0.437 1.162-1.175 1.337-1.187-0.25 0.4 0.050 0.2-0.15 0.55 0.55-0.9-0.25-0.375 0.575-1.55l0.3 0.412c-0.112-0.75 0.925-1.651 0.825-2.827 0.237-0.375 0.25 0.375 0 1.212 0.362-0.925 0.1-1.062 0.187-1.824 0.1 0.215 0.198 0.476 0.277 0.745l0.011 0.042c-0.015-0.121-0.023-0.262-0.023-0.405 0-0.581 0.138-1.13 0.382-1.615l-0.009 0.021c-0.112-0.062-0.35 0.375-0.4-0.662 0-0.462 0.125-0.25 0.175-0.35-0.252-0.292-0.423-0.66-0.474-1.066l-0.001-0.010c0.1-0.162 0.275 0.412 0.425 0.425-0.111-0.386-0.2-0.845-0.247-1.316l-0.003-0.034c-0.425-0.85-0.15 0.125-0.5-0.375-0.425-1.363 0.375-0.312 0.425-0.925 0.533 0.885 0.956 1.911 1.212 3.002l0.014 0.073c-0.151-0.837-0.363-1.575-0.64-2.28l0.028 0.081c0.2 0.087-0.325-1.551 0.262-0.462-0.805-2.376-2.428-4.295-4.526-5.464l-0.050-0.025c0.225 0.212 0.525 0.487 0.412 0.525-0.937-0.562-0.775-0.6-0.912-0.837-0.762-0.312-0.812 0.025-1.325 0-0.865-0.449-1.877-0.854-2.933-1.158l-0.119-0.029 0.062 0.287c-0.962-0.312-1.125 0.125-2.162 0-0.063-0.050 0.337-0.175 0.662-0.225-0.926 0.125-0.876-0.175-1.788 0.038 0.194-0.132 0.419-0.265 0.652-0.384l0.035-0.016c-0.75 0.050-1.799 0.437-1.475 0.087-1.776 0.642-3.315 1.483-4.697 2.52l0.046-0.033-0.036-0.275c-0.562 0.675-2.449 2.013-2.599 2.888l-0.164 0.037c-0.287 0.5-0.475 1.062-0.712 1.576-0.375 0.65-0.562 0.25-0.5 0.35-0.534 1.086-1.027 2.373-1.408 3.708l-0.041 0.169c0.074 0.691 0.116 1.493 0.116 2.305 0 0.402-0.010 0.802-0.031 1.199l0.002-0.056c-0.003 0.111-0.005 0.242-0.005 0.374 0 6.747 4.321 12.485 10.347 14.597l0.108 0.033c0.811 0.203 1.743 0.32 2.702 0.32 0.144 0 0.288-0.003 0.43-0.008l-0.021 0.001c-1.237-0.35-1.4-0.187-2.599-0.612-0.875-0.4-1.062-0.875-1.675-1.412l0.25 0.437c-1.213-0.425-0.712-0.525-1.701-0.837l0.262-0.337c-0.519-0.189-0.94-0.545-1.206-1.001l-0.006-0.011-0.425 0.012c-0.512-0.626-0.787-1.088-0.762-1.451l-0.139 0.25c-0.162-0.262-1.899-2.376-1-1.888-0.258-0.179-0.469-0.409-0.62-0.677l-0.005-0.010 0.175-0.212c-0.364-0.413-0.633-0.918-0.77-1.476l-0.005-0.024c0.131 0.198 0.326 0.345 0.555 0.411l0.007 0.002c-1.1-2.714-1.162-0.15-2.001-2.752l0.187-0.025c-0.104-0.174-0.213-0.383-0.309-0.599l-0.016-0.039 0.075-0.75c-0.787-0.925-0.225-3.876-0.112-5.501 0.338-0.964 0.709-1.781 1.142-2.559l-0.043 0.083-0.262-0.050c0.5-0.887 2.925-3.589 4.050-3.45 0.537-0.687-0.112 0-0.225-0.175 1.2-1.238 1.575-0.875 2.376-1.1 0.875-0.501-0.75 0.2-0.337-0.189 1.5-0.375 1.062-0.875 3.025-1.062 0.2 0.125-0.487 0.175-0.65 0.325 0.719-0.231 1.545-0.365 2.403-0.365 1.194 0 2.328 0.259 3.349 0.723l-0.051-0.021c2.392 1.275 4.071 3.617 4.408 6.373l0.004 0.040 0.1 0.025c0.024 0.284 0.038 0.615 0.038 0.949 0 0.863-0.091 1.705-0.264 2.517l0.014-0.079 0.25-0.525zM17 1.542l-0.187 0.037 0.175-0.012v-0.025zM16.475 1.392c0.25 0.050 0.562 0.087 0.525 0.15 0.287-0.062 0.35-0.125-0.537-0.15zM22.001 13.632c0.062-0.901-0.175-0.626-0.25-0.276 0.087 0.050 0.162 0.625 0.25 0.275zM21.025 16.194c0.274-0.375 0.479-0.82 0.583-1.302l0.004-0.023c-0.099 0.347-0.24 0.65-0.42 0.925l0.008-0.013c-0.937 0.587-0.087-0.337 0-0.7-1 1.262-0.137 0.75-0.175 1.112zM18.349 16.856c-0.5 0 0.1 0.25 0.751 0.35 0.18-0.135 0.339-0.27 0.489-0.414l-0.002 0.002c-0.242 0.056-0.52 0.087-0.805 0.087-0.152 0-0.302-0.009-0.45-0.027l0.018 0.002z"
      >
      </path>
    </svg>
    """
  end

  def icon(%{name: "os-manjaro"} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 32 32"
      version="1.1"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Manjaro</title>
      <path
        style="fill:currentColor;stroke:currentColor;"
        d="M0 0v32h9v-23h11.5v-9zM11.5 11.5v20.5h9v-20.5zM23 0v32h9v-32z"
      />
    </svg>
    """
  end

  def icon(%{name: _other} = assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 304.998 304.998"
      stroke="currentColor"
      class={["inline-block", @class]}
      {@rest}
    >
      <title>Linux</title>
      <path
        style="fill:currentColor;stroke:currentColor;"
        d="M274.659,244.888c-8.944-3.663-12.77-8.524-12.4-15.777c0.381-8.466-4.422-14.667-6.703-17.117   c1.378-5.264,5.405-23.474,0.004-39.291c-5.804-16.93-23.524-42.787-41.808-68.204c-7.485-10.438-7.839-21.784-8.248-34.922   c-0.392-12.531-0.834-26.735-7.822-42.525C190.084,9.859,174.838,0,155.851,0c-11.295,0-22.889,3.53-31.811,9.684   c-18.27,12.609-15.855,40.1-14.257,58.291c0.219,2.491,0.425,4.844,0.545,6.853c1.064,17.816,0.096,27.206-1.17,30.06   c-0.819,1.865-4.851,7.173-9.118,12.793c-4.413,5.812-9.416,12.4-13.517,18.539c-4.893,7.387-8.843,18.678-12.663,29.597   c-2.795,7.99-5.435,15.537-8.005,20.047c-4.871,8.676-3.659,16.766-2.647,20.505c-1.844,1.281-4.508,3.803-6.757,8.557   c-2.718,5.8-8.233,8.917-19.701,11.122c-5.27,1.078-8.904,3.294-10.804,6.586c-2.765,4.791-1.259,10.811,0.115,14.925   c2.03,6.048,0.765,9.876-1.535,16.826c-0.53,1.604-1.131,3.42-1.74,5.423c-0.959,3.161-0.613,6.035,1.026,8.542   c4.331,6.621,16.969,8.956,29.979,10.492c7.768,0.922,16.27,4.029,24.493,7.035c8.057,2.944,16.388,5.989,23.961,6.913   c1.151,0.145,2.291,0.218,3.39,0.218c11.434,0,16.6-7.587,18.238-10.704c4.107-0.838,18.272-3.522,32.871-3.882   c14.576-0.416,28.679,2.462,32.674,3.357c1.256,2.404,4.567,7.895,9.845,10.724c2.901,1.586,6.938,2.495,11.073,2.495   c0.001,0,0,0,0.001,0c4.416,0,12.817-1.044,19.466-8.039c6.632-7.028,23.202-16,35.302-22.551c2.7-1.462,5.226-2.83,7.441-4.065   c6.797-3.768,10.506-9.152,10.175-14.771C282.445,250.905,279.356,246.811,274.659,244.888z M124.189,243.535   c-0.846-5.96-8.513-11.871-17.392-18.715c-7.26-5.597-15.489-11.94-17.756-17.312c-4.685-11.082-0.992-30.568,5.447-40.602   c3.182-5.024,5.781-12.643,8.295-20.011c2.714-7.956,5.521-16.182,8.66-19.783c4.971-5.622,9.565-16.561,10.379-25.182   c4.655,4.444,11.876,10.083,18.547,10.083c1.027,0,2.024-0.134,2.977-0.403c4.564-1.318,11.277-5.197,17.769-8.947   c5.597-3.234,12.499-7.222,15.096-7.585c4.453,6.394,30.328,63.655,32.972,82.044c2.092,14.55-0.118,26.578-1.229,31.289   c-0.894-0.122-1.96-0.221-3.08-0.221c-7.207,0-9.115,3.934-9.612,6.283c-1.278,6.103-1.413,25.618-1.427,30.003   c-2.606,3.311-15.785,18.903-34.706,21.706c-7.707,1.12-14.904,1.688-21.39,1.688c-5.544,0-9.082-0.428-10.551-0.651l-9.508-10.879   C121.429,254.489,125.177,250.583,124.189,243.535z M136.254,64.149c-0.297,0.128-0.589,0.265-0.876,0.411   c-0.029-0.644-0.096-1.297-0.199-1.952c-1.038-5.975-5-10.312-9.419-10.312c-0.327,0-0.656,0.025-1.017,0.08   c-2.629,0.438-4.691,2.413-5.821,5.213c0.991-6.144,4.472-10.693,8.602-10.693c4.85,0,8.947,6.536,8.947,14.272   C136.471,62.143,136.4,63.113,136.254,64.149z M173.94,68.756c0.444-1.414,0.684-2.944,0.684-4.532   c0-7.014-4.45-12.509-10.131-12.509c-5.552,0-10.069,5.611-10.069,12.509c0,0.47,0.023,0.941,0.067,1.411   c-0.294-0.113-0.581-0.223-0.861-0.329c-0.639-1.935-0.962-3.954-0.962-6.015c0-8.387,5.36-15.211,11.95-15.211   c6.589,0,11.95,6.824,11.95,15.211C176.568,62.78,175.605,66.11,173.94,68.756z M169.081,85.08   c-0.095,0.424-0.297,0.612-2.531,1.774c-1.128,0.587-2.532,1.318-4.289,2.388l-1.174,0.711c-4.718,2.86-15.765,9.559-18.764,9.952   c-2.037,0.274-3.297-0.516-6.13-2.441c-0.639-0.435-1.319-0.897-2.044-1.362c-5.107-3.351-8.392-7.042-8.763-8.485   c1.665-1.287,5.792-4.508,7.905-6.415c4.289-3.988,8.605-6.668,10.741-6.668c0.113,0,0.215,0.008,0.321,0.028   c2.51,0.443,8.701,2.914,13.223,4.718c2.09,0.834,3.895,1.554,5.165,2.01C166.742,82.664,168.828,84.422,169.081,85.08z    M205.028,271.45c2.257-10.181,4.857-24.031,4.436-32.196c-0.097-1.855-0.261-3.874-0.42-5.826   c-0.297-3.65-0.738-9.075-0.283-10.684c0.09-0.042,0.19-0.078,0.301-0.109c0.019,4.668,1.033,13.979,8.479,17.226   c2.219,0.968,4.755,1.458,7.537,1.458c7.459,0,15.735-3.659,19.125-7.049c1.996-1.996,3.675-4.438,4.851-6.372   c0.257,0.753,0.415,1.737,0.332,3.005c-0.443,6.885,2.903,16.019,9.271,19.385l0.927,0.487c2.268,1.19,8.292,4.353,8.389,5.853   c-0.001,0.001-0.051,0.177-0.387,0.489c-1.509,1.379-6.82,4.091-11.956,6.714c-9.111,4.652-19.438,9.925-24.076,14.803   c-6.53,6.872-13.916,11.488-18.376,11.488c-0.537,0-1.026-0.068-1.461-0.206C206.873,288.406,202.886,281.417,205.028,271.45z    M39.917,245.477c-0.494-2.312-0.884-4.137-0.465-5.905c0.304-1.31,6.771-2.714,9.533-3.313c3.883-0.843,7.899-1.714,10.525-3.308   c3.551-2.151,5.474-6.118,7.17-9.618c1.228-2.531,2.496-5.148,4.005-6.007c0.085-0.05,0.215-0.108,0.463-0.108   c2.827,0,8.759,5.943,12.177,11.262c0.867,1.341,2.473,4.028,4.331,7.139c5.557,9.298,13.166,22.033,17.14,26.301   c3.581,3.837,9.378,11.214,7.952,17.541c-1.044,4.909-6.602,8.901-7.913,9.784c-0.476,0.108-1.065,0.163-1.758,0.163   c-7.606,0-22.662-6.328-30.751-9.728l-1.197-0.503c-4.517-1.894-11.891-3.087-19.022-4.241c-5.674-0.919-13.444-2.176-14.732-3.312   c-1.044-1.171,0.167-4.978,1.235-8.337c0.769-2.414,1.563-4.91,1.998-7.523C41.225,251.596,40.499,248.203,39.917,245.477z"
      />
    </svg>
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
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    colors = %{
      "success" => "bg-green-100 text-green-800 ",
      "danger" => "bg-red-100 text-red-800",
      "warning" => "bg-yellow-100 text-yellow-800",
      "info" => "bg-blue-100 text-blue-800",
      "primary" => "bg-primary-400 text-primary-800",
      "accent" => "bg-accent-200 text-accent-800",
      "neutral" => "bg-neutral-100 text-neutral-800"
    }

    assigns = assign(assigns, colors: colors)

    ~H"""
    <span
      class={[
        "text-xs px-2.5 py-0.5 rounded whitespace-nowrap",
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
        "light" => "bg-green-100 text-green-800"
      },
      "danger" => %{
        "dark" => "bg-red-300 text-red-800",
        "light" => "bg-red-100 text-red-800"
      },
      "warning" => %{
        "dark" => "bg-yellow-300 text-yellow-800",
        "light" => "bg-yellow-100 text-yellow-800"
      },
      "info" => %{
        "dark" => "bg-blue-300 text-blue-800",
        "light" => "bg-blue-100 text-blue-800"
      },
      "primary" => %{
        "dark" => "bg-primary-400 text-primary-800",
        "light" => "bg-primary-100 text-primary-800"
      },
      "accent" => %{
        "dark" => "bg-accent-100 text-accent-800",
        "light" => "bg-accent-50 text-accent-800"
      },
      "neutral" => %{
        "dark" => "bg-neutral-100 text-neutral-800",
        "light" => "bg-neutral-50 text-neutral-800"
      }
    }

    assigns = assign(assigns, colors: colors)

    ~H"""
    <span class="flex inline-flex">
      <div class={[
        "text-xs rounded-l py-0.5 pl-2.5 pr-1.5",
        @colors[@type]["dark"]
      ]}>
        {render_slot(@left)}
      </div>
      <span class={[
        "text-xs",
        "rounded-r",
        "mr-2 py-0.5 pl-1.5 pr-2.5",
        @colors[@type]["light"]
      ]}>
        {render_slot(@right)}
      </span>
    </span>
    """
  end

  @doc """
  Renders datetime field in a format that is suitable for the user's locale.
  """
  attr :datetime, DateTime, required: true
  attr :format, :atom, default: :short

  def datetime(assigns) do
    ~H"""
    <span title={@datetime}>
      {Cldr.DateTime.to_string!(@datetime, Portal.CLDR, format: @format)}
    </span>
    """
  end

  @doc """
  Returns a string the represents a relative time for a given Datetime
  from the current time or a given base time
  """
  attr :datetime, DateTime, default: nil
  attr :relative_to, DateTime, required: false
  attr :negative_class, :string, default: ""
  attr :popover, :boolean, default: true

  def relative_datetime(assigns) do
    assigns =
      assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    ~H"""
    <.popover :if={not is_nil(@datetime) and @popover}>
      <:target>
        <span class={[
          "underline underline-offset-2 decoration-1 decoration-dotted",
          DateTime.compare(@datetime, @relative_to) == :lt && @negative_class
        ]}>
          {Cldr.DateTime.Relative.to_string!(@datetime, Portal.CLDR, relative_to: @relative_to)
          |> String.capitalize()}
        </span>
      </:target>
      <:content>
        {@datetime}
      </:content>
    </.popover>
    <span :if={not @popover}>
      {Cldr.DateTime.Relative.to_string!(@datetime, Portal.CLDR, relative_to: @relative_to)
      |> String.capitalize()}
    </span>
    <span :if={is_nil(@datetime)}>
      Never
    </span>
    """
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

    ~H"""
    <span
      phx-hook="Popover"
      id={@target_id <> "-trigger"}
      data-popover-target-id={@target_id}
      data-popover-placement={@placement}
      data-popover-trigger={@trigger}
    >
      {render_slot(@target)}
    </span>

    <div data-popover id={@target_id} role="tooltip" class={~w[
      absolute z-10 invisible inline-block
      text-sm text-neutral-500 transition-opacity
      duration-50 bg-white border border-neutral-200
      rounded-lg shadow-sm opacity-0
      ]}>
      <div class="px-3 py-2">
        {render_slot(@content)}
      </div>
      <div data-popper-arrow></div>
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

    ~H"""
    <span class={["flex items-center", @class]}>
      <.ping_icon color={if @schema.online?, do: "success", else: "danger"} />
      <span
        class="ml-2.5"
        title={
          if @schema.last_seen_at,
            do:
              "Last started #{Cldr.DateTime.Relative.to_string!(@schema.last_seen_at, Portal.CLDR, relative_to: @relative_to)}",
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
        <.icon name="spinner" class="animate-spin h-3.5 w-3.5 mr-1" /> Waiting for connection...
      </span>

      <span :if={@connected?}>
        <.icon name="hero-check" class="h-3.5 w-3.5 mr-1" /> Connected, click to continue
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
      <.icon name="hero-shield-check" class="w-4 h-4" /> Verified
      <.relative_datetime datetime={@schema.verified_at} />
    </div>
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true

  def actor_link(%{actor: %Portal.Actor{type: :api_client}} = assigns) do
    ~H"""
    <.link class={link_style()} navigate={~p"/#{@account}/settings/api_clients/#{@actor}"}>
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
  """
  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :class, :string, default: nil
  attr :return_to, :string, default: nil

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
        "inline-flex items-center rounded border border-neutral-200 overflow-hidden mr-1",
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
        <.provider_icon type={provider_type_from_group(@group)} class="h-3.5 w-3.5" />
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
        <.provider_icon type={provider_type_from_group(@group)} class="h-2.5 w-2.5" />
      </span>
      <.link
        title={"View Group \"#{@group.name}\""}
        navigate={@navigate_url}
        class={[
          "text-xs truncate min-w-0 py-0.5 text-neutral-900 bg-neutral-50",
          if(@group.idp_id, do: "rounded-r pl-1.5 pr-2.5", else: "rounded px-2.5")
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
    ~H"""
    <span class="inline-block">
      {@schema.last_seen_remote_ip}
    </span>
    <span class="inline-block">
      {[
        @schema.last_seen_remote_ip_location_city,
        Portal.Geo.country_common_name!(@schema.last_seen_remote_ip_location_region)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")}

      <a
        :if={
          not is_nil(@schema.last_seen_remote_ip_location_lat) and
            not is_nil(@schema.last_seen_remote_ip_location_lon)
        }
        class="text-accent-800"
        target="_blank"
        href={"http://www.google.com/maps/place/#{@schema.last_seen_remote_ip_location_lat},#{@schema.last_seen_remote_ip_location_lon}"}
      >
        <.icon name="hero-arrow-top-right-on-square" class="mb-3 w-3 h-3" />
      </a>
    </span>
    """
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
      {Portal.CLDR.Number.Cardinal.pluralize(@number, :en, @opts)}
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
      "success" -> {"bg-green-500", "bg-green-400"}
      "warning" -> {"bg-orange-500", "bg-orange-400"}
      "danger" -> {"bg-red-500", "bg-red-400"}
    end
  end

  @doc """
  Helper function to get provider type from group.
  Groups have a directory_type field that indicates the provider.
  If the group has idp_id but no directory_type, it's synced but we can't determine the provider.
  """
  def provider_type_from_group(%{directory_type: type}) when not is_nil(type), do: to_string(type)
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

  <.provider_icon type={:google} class="w-5 h-5 mr-2" />
  """
  attr :type, :string, required: true
  attr :rest, :global

  def provider_icon(%{type: "firezone"} = assigns) do
    ~H"""
    <img src={~p"/images/logo.svg"} alt="Firezone Logo" {@rest} />
    """
  end

  def provider_icon(%{type: "okta"} = assigns) do
    ~H"""
    <img src={~p"/images/okta-logo.svg"} alt="Okta Logo" {@rest} />
    """
  end

  def provider_icon(%{type: "email_otp"} = assigns) do
    ~H"""
    <.icon name="hero-envelope" {@rest} />
    """
  end

  def provider_icon(%{type: "oidc"} = assigns) do
    ~H"""
    <img src={~p"/images/openid-logo.svg"} alt="OpenID Connect Logo" {@rest} />
    """
  end

  def provider_icon(%{type: "google"} = assigns) do
    ~H"""
    <img src={~p"/images/google-logo.svg"} alt="Google Workspace Logo" {@rest} />
    """
  end

  def provider_icon(%{type: "entra"} = assigns) do
    ~H"""
    <img src={~p"/images/entra-logo.svg"} alt="Microsoft Entra Logo" {@rest} />
    """
  end

  def provider_icon(%{type: "userpass"} = assigns) do
    ~H"""
    <.icon name="hero-key" {@rest} />
    """
  end

  def provider_icon(%{type: "unknown"} = assigns) do
    ~H"""
    <.icon name="hero-question-mark-circle" {@rest} />
    """
  end

  def provider_icon(assigns), do: ~H""

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

  def feature_name(%{feature: :multi_site_resources} = assigns) do
    ~H"""
    Define globally-distributed Resources
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
  attr :class, :string, default: nil
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <label class={["inline-flex items-center cursor-pointer", @class]}>
      <input
        type="checkbox"
        id={@id}
        checked={@checked}
        disabled={@disabled}
        class="sr-only peer"
        {@rest}
      />
      <div class={[
        "relative w-11 h-6 bg-gray-200 rounded-full peer",
        "peer-focus:outline-none peer-focus:ring-4 peer-focus:ring-accent-300",
        "peer-checked:after:translate-x-full rtl:peer-checked:after:-translate-x-full",
        "peer-checked:after:border-white after:content-[''] after:absolute after:top-[2px]",
        "after:start-[2px] after:bg-white after:border-gray-300 after:border",
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
end
