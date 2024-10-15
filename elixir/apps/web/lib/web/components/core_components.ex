defmodule Web.CoreComponents do
  @moduledoc """
  Provides core UI components.

  The components in this module use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn how to
  customize the generated components in this module.

  Icons are provided by [heroicons](https://heroicons.com), using the
  [heroicons_elixir](https://github.com/mveytsman/heroicons_elixir) project.
  """
  use Phoenix.Component
  use Web, :verified_routes
  alias Phoenix.LiveView.JS
  alias Domain.Actors

  attr :text, :string, default: "Welcome to Firezone."

  def hero_logo(assigns) do
    ~H"""
    <div class="mb-6">
      <img src={~p"/images/logo.svg"} class="mx-auto pr-10 h-24" alt="Firezone Logo" />
      <p class="text-center mt-4 text-3xl">
        <%= @text %>
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
    <p class="text-neutral-700"><%= render_slot(@inner_block) %></p>
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
    <div id={@id} class="relative">
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
        data-copy-to-clipboard-content-type="innerHTML"
        data-copy-to-clipboard-html-entities="true"
        title="Click to copy"
        class={[
          "absolute top-1 right-1",
          "items-center",
          "cursor-pointer",
          "rounded",
          "p-1",
          "bg-neutral-50/25",
          "text-xs text-neutral-50",
          "hover:bg-neutral-50 hover:text-neutral-900 hover:opacity-50"
        ]}
      >
        <.icon name="hero-clipboard-document" data-icon class="h-4 w-4" />
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
    <div id={@id} class={@class} {@rest}>
      <code id={"#{@id}-code"} phx-no-format><%= render_slot(@inner_block) %></code>
      <button
        type="button"
        class={~w[text-neutral-400 cursor-pointer rounded]}
        data-copy-to-clipboard-target={"#{@id}-code"}
        data-copy-to-clipboard-content-type="innerHTML"
        data-copy-to-clipboard-html-entities="true"
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
                  <%= tab.label %>
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
            <%= render_slot(tab) %>
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
              <%= render_slot(@title) %>
            </h2>
            <div class="inline-flex justify-between items-center space-x-2">
              <%= render_slot(@actions) %>
            </div>
          </div>
        </div>
      </div>
      <div :for={help <- @help} class="pt-3 text-neutral-400">
        <%= render_slot(help) %>
      </div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, default: "flash", doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil

  attr :kind, :atom,
    values: [:success, :info, :warning, :error],
    doc: "used for styling and flash lookup"

  attr :class, :any, default: nil
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  attr :style, :string, default: "pill"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      class={[
        "p-4 text-sm flash-#{@kind}",
        @kind == :success && "text-green-800 bg-green-100",
        @kind == :info && "text-blue-800 bg-blue-100",
        @kind == :warning && "text-yellow-800 bg-yellow-100",
        @kind == :error && "text-red-800 bg-red-100",
        @style != "wide" && "mb-4 rounded",
        @class
      ]}
      role="alert"
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <.icon :if={@kind == :info} name="hero-information-circle-mini" class="h-4 w-4" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle-mini" class="h-4 w-4" />
        <%= @title %>
      </p>
      <%= maybe_render_changeset_as_flash(msg) %>
    </div>
    """
  end

  def maybe_render_changeset_as_flash({:validation_errors, message, errors}) do
    assigns = %{message: message, errors: errors}

    ~H"""
    <%= @message %>:
    <ul>
      <li :for={{field, field_errors} <- @errors}>
        <%= field %>: <%= Enum.join(field_errors, ", ") %>
      </li>
    </ul>
    """
  end

  def maybe_render_changeset_as_flash(other) do
    other
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  def flash_group(assigns) do
    ~H"""
    <.flash kind={:info} title="Success!" flash={@flash} />
    <.flash kind={:error} title="Error!" flash={@flash} />
    <.flash
      id="disconnected"
      kind={:error}
      title="We can't find the internet"
      phx-disconnected={show("#disconnected")}
      phx-connected={hide("#disconnected")}
      hidden
    >
      Attempting to reconnect <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
    </.flash>
    """
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
      <%= render_slot(@inner_block) %>
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
      <%= render_slot(@inner_block) %>
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
      <%= translate_error(@error) %>
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
          <dt class="w-1/4 flex-none text-neutral-500"><%= item.title %></dt>
          <dd class="text-neutral-700"><%= render_slot(item) %></dd>
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
    <.icon name="hero-device-phone-mobile" class={@class} {@rest} />

    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 50 50"
      class={["inline-block", @class]}
      {@rest}
    >
      <path d="M 16.375 -0.03125 C 16.332031 -0.0234375 16.289063 -0.0117188 16.25 0 C 15.921875 0.0742188 15.652344 0.304688 15.53125 0.621094 C 15.410156 0.9375 15.457031 1.289063 15.65625 1.5625 L 17.78125 4.75 C 14.183594 6.640625 11.601563 9.902344 11 13.78125 C 11 13.792969 11 13.800781 11 13.8125 C 11 13.824219 11 13.832031 11 13.84375 C 11 13.875 11 13.90625 11 13.9375 C 11 13.957031 11 13.980469 11 14 C 10.996094 14.050781 10.996094 14.105469 11 14.15625 L 11 15.5625 C 10.40625 15.214844 9.734375 15 9 15 C 6.800781 15 5 16.800781 5 19 L 5 31 C 5 33.199219 6.800781 35 9 35 C 9.734375 35 10.40625 34.785156 11 34.4375 L 11 37 C 11 38.644531 12.355469 40 14 40 L 15 40 L 15 46 C 15 48.199219 16.800781 50 19 50 C 21.199219 50 23 48.199219 23 46 L 23 40 L 27 40 L 27 46 C 27 48.199219 28.800781 50 31 50 C 33.199219 50 35 48.199219 35 46 L 35 40 L 36 40 C 37.644531 40 39 38.644531 39 37 L 39 34.4375 C 39.59375 34.785156 40.265625 35 41 35 C 43.199219 35 45 33.199219 45 31 L 45 19 C 45 16.800781 43.199219 15 41 15 C 40.265625 15 39.59375 15.214844 39 15.5625 L 39 14.1875 C 39.011719 14.09375 39.011719 14 39 13.90625 C 39 13.894531 39 13.886719 39 13.875 C 39 13.863281 39 13.855469 39 13.84375 C 38.417969 9.9375 35.835938 6.648438 32.21875 4.75 L 34.34375 1.5625 C 34.589844 1.226563 34.597656 0.773438 34.367188 0.425781 C 34.140625 0.078125 33.71875 -0.09375 33.3125 0 C 33.054688 0.0585938 32.828125 0.214844 32.6875 0.4375 L 30.34375 3.90625 C 28.695313 3.3125 26.882813 3 25 3 C 23.117188 3 21.304688 3.3125 19.65625 3.90625 L 17.3125 0.4375 C 17.113281 0.117188 16.75 -0.0625 16.375 -0.03125 Z M 25 5 C 26.878906 5 28.640625 5.367188 30.1875 6.03125 C 30.21875 6.042969 30.25 6.054688 30.28125 6.0625 C 33.410156 7.433594 35.6875 10 36.5625 13 L 13.4375 13 C 14.300781 10.042969 16.53125 7.507813 19.59375 6.125 C 19.660156 6.101563 19.722656 6.070313 19.78125 6.03125 C 21.335938 5.359375 23.109375 5 25 5 Z M 19.5 8 C 18.667969 8 18 8.671875 18 9.5 C 18 10.332031 18.667969 11 19.5 11 C 20.328125 11 21 10.332031 21 9.5 C 21 8.671875 20.328125 8 19.5 8 Z M 30.5 8 C 29.671875 8 29 8.671875 29 9.5 C 29 10.332031 29.671875 11 30.5 11 C 31.332031 11 32 10.332031 32 9.5 C 32 8.671875 31.332031 8 30.5 8 Z M 13 15 L 37 15 L 37 37 C 37 37.5625 36.5625 38 36 38 L 28.1875 38 C 28.054688 37.972656 27.914063 37.972656 27.78125 38 L 16.1875 38 C 16.054688 37.972656 15.914063 37.972656 15.78125 38 L 14 38 C 13.4375 38 13 37.5625 13 37 Z M 9 17 C 10.117188 17 11 17.882813 11 19 L 11 31 C 11 32.117188 10.117188 33 9 33 C 7.882813 33 7 32.117188 7 31 L 7 19 C 7 17.882813 7.882813 17 9 17 Z M 41 17 C 42.117188 17 43 17.882813 43 19 L 43 31 C 43 32.117188 42.117188 33 41 33 C 39.882813 33 39 32.117188 39 31 L 39 19 C 39 17.882813 39.882813 17 41 17 Z M 17 40 L 21 40 L 21 46 C 21 47.117188 20.117188 48 19 48 C 17.882813 48 17 47.117188 17 46 Z M 29 40 L 33 40 L 33 46 C 33 47.117188 32.117188 48 31 48 C 29.882813 48 29 47.117188 29 46 Z">
      </path>
    </svg>
    """
  end

  def icon(%{name: "os-ios"} = assigns) do
    ~H"""
    <.icon name="hero-device-phone-mobile" class={@class} {@rest} />

    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 50 50"
      class={["inline-block", @class]}
      {@rest}
    >
      <path d="M 33.375 0 C 30.539063 0.191406 27.503906 1.878906 25.625 4.15625 C 23.980469 6.160156 22.601563 9.101563 23.125 12.15625 C 22.65625 12.011719 22.230469 11.996094 21.71875 11.8125 C 20.324219 11.316406 18.730469 10.78125 16.75 10.78125 C 12.816406 10.78125 8.789063 13.121094 6.25 17.03125 C 2.554688 22.710938 3.296875 32.707031 8.90625 41.25 C 9.894531 42.75 11.046875 44.386719 12.46875 45.6875 C 13.890625 46.988281 15.609375 47.980469 17.625 48 C 19.347656 48.019531 20.546875 47.445313 21.625 46.96875 C 22.703125 46.492188 23.707031 46.070313 25.59375 46.0625 C 25.605469 46.0625 25.613281 46.0625 25.625 46.0625 C 27.503906 46.046875 28.476563 46.460938 29.53125 46.9375 C 30.585938 47.414063 31.773438 48.015625 33.5 48 C 35.554688 47.984375 37.300781 46.859375 38.75 45.46875 C 40.199219 44.078125 41.390625 42.371094 42.375 40.875 C 43.785156 38.726563 44.351563 37.554688 45.4375 35.15625 C 45.550781 34.90625 45.554688 34.617188 45.445313 34.363281 C 45.339844 34.109375 45.132813 33.910156 44.875 33.8125 C 41.320313 32.46875 39.292969 29.324219 39 26 C 38.707031 22.675781 40.113281 19.253906 43.65625 17.3125 C 43.917969 17.171875 44.101563 16.925781 44.164063 16.636719 C 44.222656 16.347656 44.152344 16.042969 43.96875 15.8125 C 41.425781 12.652344 37.847656 10.78125 34.34375 10.78125 C 32.109375 10.78125 30.46875 11.308594 29.125 11.8125 C 28.902344 11.898438 28.738281 11.890625 28.53125 11.96875 C 29.894531 11.25 31.097656 10.253906 32 9.09375 C 33.640625 6.988281 34.90625 3.992188 34.4375 0.84375 C 34.359375 0.328125 33.894531 -0.0390625 33.375 0 Z M 32.3125 2.375 C 32.246094 4.394531 31.554688 6.371094 30.40625 7.84375 C 29.203125 9.390625 27.179688 10.460938 25.21875 10.78125 C 25.253906 8.839844 26.019531 6.828125 27.1875 5.40625 C 28.414063 3.921875 30.445313 2.851563 32.3125 2.375 Z M 16.75 12.78125 C 18.363281 12.78125 19.65625 13.199219 21.03125 13.6875 C 22.40625 14.175781 23.855469 14.75 25.5625 14.75 C 27.230469 14.75 28.550781 14.171875 29.84375 13.6875 C 31.136719 13.203125 32.425781 12.78125 34.34375 12.78125 C 36.847656 12.78125 39.554688 14.082031 41.6875 16.34375 C 38.273438 18.753906 36.675781 22.511719 37 26.15625 C 37.324219 29.839844 39.542969 33.335938 43.1875 35.15625 C 42.398438 36.875 41.878906 38.011719 40.71875 39.78125 C 39.761719 41.238281 38.625 42.832031 37.375 44.03125 C 36.125 45.230469 34.800781 45.988281 33.46875 46 C 32.183594 46.011719 31.453125 45.628906 30.34375 45.125 C 29.234375 44.621094 27.800781 44.042969 25.59375 44.0625 C 23.390625 44.074219 21.9375 44.628906 20.8125 45.125 C 19.6875 45.621094 18.949219 46.011719 17.65625 46 C 16.289063 45.988281 15.019531 45.324219 13.8125 44.21875 C 12.605469 43.113281 11.515625 41.605469 10.5625 40.15625 C 5.3125 32.15625 4.890625 22.757813 7.90625 18.125 C 10.117188 14.722656 13.628906 12.78125 16.75 12.78125 Z">
      </path>
    </svg>
    """
  end

  def icon(%{name: "os-macos"} = assigns) do
    ~H"""
    <.icon name="hero-computer-desktop" class={@class} {@rest} />

    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 50 50"
      class={["inline-block", @class]}
      {@rest}
    >
      <path d="M 33.375 0 C 30.539063 0.191406 27.503906 1.878906 25.625 4.15625 C 23.980469 6.160156 22.601563 9.101563 23.125 12.15625 C 22.65625 12.011719 22.230469 11.996094 21.71875 11.8125 C 20.324219 11.316406 18.730469 10.78125 16.75 10.78125 C 12.816406 10.78125 8.789063 13.121094 6.25 17.03125 C 2.554688 22.710938 3.296875 32.707031 8.90625 41.25 C 9.894531 42.75 11.046875 44.386719 12.46875 45.6875 C 13.890625 46.988281 15.609375 47.980469 17.625 48 C 19.347656 48.019531 20.546875 47.445313 21.625 46.96875 C 22.703125 46.492188 23.707031 46.070313 25.59375 46.0625 C 25.605469 46.0625 25.613281 46.0625 25.625 46.0625 C 27.503906 46.046875 28.476563 46.460938 29.53125 46.9375 C 30.585938 47.414063 31.773438 48.015625 33.5 48 C 35.554688 47.984375 37.300781 46.859375 38.75 45.46875 C 40.199219 44.078125 41.390625 42.371094 42.375 40.875 C 43.785156 38.726563 44.351563 37.554688 45.4375 35.15625 C 45.550781 34.90625 45.554688 34.617188 45.445313 34.363281 C 45.339844 34.109375 45.132813 33.910156 44.875 33.8125 C 41.320313 32.46875 39.292969 29.324219 39 26 C 38.707031 22.675781 40.113281 19.253906 43.65625 17.3125 C 43.917969 17.171875 44.101563 16.925781 44.164063 16.636719 C 44.222656 16.347656 44.152344 16.042969 43.96875 15.8125 C 41.425781 12.652344 37.847656 10.78125 34.34375 10.78125 C 32.109375 10.78125 30.46875 11.308594 29.125 11.8125 C 28.902344 11.898438 28.738281 11.890625 28.53125 11.96875 C 29.894531 11.25 31.097656 10.253906 32 9.09375 C 33.640625 6.988281 34.90625 3.992188 34.4375 0.84375 C 34.359375 0.328125 33.894531 -0.0390625 33.375 0 Z M 32.3125 2.375 C 32.246094 4.394531 31.554688 6.371094 30.40625 7.84375 C 29.203125 9.390625 27.179688 10.460938 25.21875 10.78125 C 25.253906 8.839844 26.019531 6.828125 27.1875 5.40625 C 28.414063 3.921875 30.445313 2.851563 32.3125 2.375 Z M 16.75 12.78125 C 18.363281 12.78125 19.65625 13.199219 21.03125 13.6875 C 22.40625 14.175781 23.855469 14.75 25.5625 14.75 C 27.230469 14.75 28.550781 14.171875 29.84375 13.6875 C 31.136719 13.203125 32.425781 12.78125 34.34375 12.78125 C 36.847656 12.78125 39.554688 14.082031 41.6875 16.34375 C 38.273438 18.753906 36.675781 22.511719 37 26.15625 C 37.324219 29.839844 39.542969 33.335938 43.1875 35.15625 C 42.398438 36.875 41.878906 38.011719 40.71875 39.78125 C 39.761719 41.238281 38.625 42.832031 37.375 44.03125 C 36.125 45.230469 34.800781 45.988281 33.46875 46 C 32.183594 46.011719 31.453125 45.628906 30.34375 45.125 C 29.234375 44.621094 27.800781 44.042969 25.59375 44.0625 C 23.390625 44.074219 21.9375 44.628906 20.8125 45.125 C 19.6875 45.621094 18.949219 46.011719 17.65625 46 C 16.289063 45.988281 15.019531 45.324219 13.8125 44.21875 C 12.605469 43.113281 11.515625 41.605469 10.5625 40.15625 C 5.3125 32.15625 4.890625 22.757813 7.90625 18.125 C 10.117188 14.722656 13.628906 12.78125 16.75 12.78125 Z" />
    </svg>
    """
  end

  def icon(%{name: "os-windows"} = assigns) do
    ~H"""
    <.icon name="hero-computer-desktop" class={@class} {@rest} />

    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 30 30"
      class={["inline-block", @class]}
      {@rest}
    >
      <path d="M1,15H12a1,1,0,0,0,1-1V4.17a1,1,0,0,0-.35-.77,1,1,0,0,0-.81-.22L.84,5A1,1,0,0,0,0,6v8A1,1,0,0,0,1,15ZM2,6.85l9-1.5V13H2Z" />
      <path d="M30.84,0l-15,2.5a1,1,0,0,0-.84,1V14a1,1,0,0,0,1,1H31a1,1,0,0,0,1-1V1a1,1,0,0,0-.35-.76A1,1,0,0,0,30.84,0ZM30,13H17V4.35L30,2.18Z" />
      <path d="M.84,27l11,1.83H12a1,1,0,0,0,1-1V18a1,1,0,0,0-1-1H1a1,1,0,0,0-1,1v8A1,1,0,0,0,.84,27ZM2,19h9v7.65l-9-1.5Z" />
      <path d="M31,17H16a1,1,0,0,0-1,1V28.5a1,1,0,0,0,.84,1l15,2.5H31a1,1,0,0,0,.65-.24A1,1,0,0,0,32,31V18A1,1,0,0,0,31,17ZM30,29.82,17,27.65V19H30Z" />
    </svg>
    """
  end

  def icon(%{name: "os-linux"} = assigns) do
    ~H"""
    <.icon name="hero-computer-desktop" class={@class} {@rest} />

    <svg
      xmlns="http://www.w3.org/2000/svg"
      xmlns:xlink="http://www.w3.org/1999/xlink"
      viewBox="0 0 304.998 304.998"
      xml:space="preserve"
      class={["inline-block", @class]}
      {@rest}
    >
      <g id="XMLID_91_">
        <path
          id="XMLID_92_"
          d="M274.659,244.888c-8.944-3.663-12.77-8.524-12.4-15.777c0.381-8.466-4.422-14.667-6.703-17.117   c1.378-5.264,5.405-23.474,0.004-39.291c-5.804-16.93-23.524-42.787-41.808-68.204c-7.485-10.438-7.839-21.784-8.248-34.922   c-0.392-12.531-0.834-26.735-7.822-42.525C190.084,9.859,174.838,0,155.851,0c-11.295,0-22.889,3.53-31.811,9.684   c-18.27,12.609-15.855,40.1-14.257,58.291c0.219,2.491,0.425,4.844,0.545,6.853c1.064,17.816,0.096,27.206-1.17,30.06   c-0.819,1.865-4.851,7.173-9.118,12.793c-4.413,5.812-9.416,12.4-13.517,18.539c-4.893,7.387-8.843,18.678-12.663,29.597   c-2.795,7.99-5.435,15.537-8.005,20.047c-4.871,8.676-3.659,16.766-2.647,20.505c-1.844,1.281-4.508,3.803-6.757,8.557   c-2.718,5.8-8.233,8.917-19.701,11.122c-5.27,1.078-8.904,3.294-10.804,6.586c-2.765,4.791-1.259,10.811,0.115,14.925   c2.03,6.048,0.765,9.876-1.535,16.826c-0.53,1.604-1.131,3.42-1.74,5.423c-0.959,3.161-0.613,6.035,1.026,8.542   c4.331,6.621,16.969,8.956,29.979,10.492c7.768,0.922,16.27,4.029,24.493,7.035c8.057,2.944,16.388,5.989,23.961,6.913   c1.151,0.145,2.291,0.218,3.39,0.218c11.434,0,16.6-7.587,18.238-10.704c4.107-0.838,18.272-3.522,32.871-3.882   c14.576-0.416,28.679,2.462,32.674,3.357c1.256,2.404,4.567,7.895,9.845,10.724c2.901,1.586,6.938,2.495,11.073,2.495   c0.001,0,0,0,0.001,0c4.416,0,12.817-1.044,19.466-8.039c6.632-7.028,23.202-16,35.302-22.551c2.7-1.462,5.226-2.83,7.441-4.065   c6.797-3.768,10.506-9.152,10.175-14.771C282.445,250.905,279.356,246.811,274.659,244.888z M124.189,243.535   c-0.846-5.96-8.513-11.871-17.392-18.715c-7.26-5.597-15.489-11.94-17.756-17.312c-4.685-11.082-0.992-30.568,5.447-40.602   c3.182-5.024,5.781-12.643,8.295-20.011c2.714-7.956,5.521-16.182,8.66-19.783c4.971-5.622,9.565-16.561,10.379-25.182   c4.655,4.444,11.876,10.083,18.547,10.083c1.027,0,2.024-0.134,2.977-0.403c4.564-1.318,11.277-5.197,17.769-8.947   c5.597-3.234,12.499-7.222,15.096-7.585c4.453,6.394,30.328,63.655,32.972,82.044c2.092,14.55-0.118,26.578-1.229,31.289   c-0.894-0.122-1.96-0.221-3.08-0.221c-7.207,0-9.115,3.934-9.612,6.283c-1.278,6.103-1.413,25.618-1.427,30.003   c-2.606,3.311-15.785,18.903-34.706,21.706c-7.707,1.12-14.904,1.688-21.39,1.688c-5.544,0-9.082-0.428-10.551-0.651l-9.508-10.879   C121.429,254.489,125.177,250.583,124.189,243.535z M136.254,64.149c-0.297,0.128-0.589,0.265-0.876,0.411   c-0.029-0.644-0.096-1.297-0.199-1.952c-1.038-5.975-5-10.312-9.419-10.312c-0.327,0-0.656,0.025-1.017,0.08   c-2.629,0.438-4.691,2.413-5.821,5.213c0.991-6.144,4.472-10.693,8.602-10.693c4.85,0,8.947,6.536,8.947,14.272   C136.471,62.143,136.4,63.113,136.254,64.149z M173.94,68.756c0.444-1.414,0.684-2.944,0.684-4.532   c0-7.014-4.45-12.509-10.131-12.509c-5.552,0-10.069,5.611-10.069,12.509c0,0.47,0.023,0.941,0.067,1.411   c-0.294-0.113-0.581-0.223-0.861-0.329c-0.639-1.935-0.962-3.954-0.962-6.015c0-8.387,5.36-15.211,11.95-15.211   c6.589,0,11.95,6.824,11.95,15.211C176.568,62.78,175.605,66.11,173.94,68.756z M169.081,85.08   c-0.095,0.424-0.297,0.612-2.531,1.774c-1.128,0.587-2.532,1.318-4.289,2.388l-1.174,0.711c-4.718,2.86-15.765,9.559-18.764,9.952   c-2.037,0.274-3.297-0.516-6.13-2.441c-0.639-0.435-1.319-0.897-2.044-1.362c-5.107-3.351-8.392-7.042-8.763-8.485   c1.665-1.287,5.792-4.508,7.905-6.415c4.289-3.988,8.605-6.668,10.741-6.668c0.113,0,0.215,0.008,0.321,0.028   c2.51,0.443,8.701,2.914,13.223,4.718c2.09,0.834,3.895,1.554,5.165,2.01C166.742,82.664,168.828,84.422,169.081,85.08z    M205.028,271.45c2.257-10.181,4.857-24.031,4.436-32.196c-0.097-1.855-0.261-3.874-0.42-5.826   c-0.297-3.65-0.738-9.075-0.283-10.684c0.09-0.042,0.19-0.078,0.301-0.109c0.019,4.668,1.033,13.979,8.479,17.226   c2.219,0.968,4.755,1.458,7.537,1.458c7.459,0,15.735-3.659,19.125-7.049c1.996-1.996,3.675-4.438,4.851-6.372   c0.257,0.753,0.415,1.737,0.332,3.005c-0.443,6.885,2.903,16.019,9.271,19.385l0.927,0.487c2.268,1.19,8.292,4.353,8.389,5.853   c-0.001,0.001-0.051,0.177-0.387,0.489c-1.509,1.379-6.82,4.091-11.956,6.714c-9.111,4.652-19.438,9.925-24.076,14.803   c-6.53,6.872-13.916,11.488-18.376,11.488c-0.537,0-1.026-0.068-1.461-0.206C206.873,288.406,202.886,281.417,205.028,271.45z    M39.917,245.477c-0.494-2.312-0.884-4.137-0.465-5.905c0.304-1.31,6.771-2.714,9.533-3.313c3.883-0.843,7.899-1.714,10.525-3.308   c3.551-2.151,5.474-6.118,7.17-9.618c1.228-2.531,2.496-5.148,4.005-6.007c0.085-0.05,0.215-0.108,0.463-0.108   c2.827,0,8.759,5.943,12.177,11.262c0.867,1.341,2.473,4.028,4.331,7.139c5.557,9.298,13.166,22.033,17.14,26.301   c3.581,3.837,9.378,11.214,7.952,17.541c-1.044,4.909-6.602,8.901-7.913,9.784c-0.476,0.108-1.065,0.163-1.758,0.163   c-7.606,0-22.662-6.328-30.751-9.728l-1.197-0.503c-4.517-1.894-11.891-3.087-19.022-4.241c-5.674-0.919-13.444-2.176-14.732-3.312   c-1.044-1.171,0.167-4.978,1.235-8.337c0.769-2.414,1.563-4.91,1.998-7.523C41.225,251.596,40.499,248.203,39.917,245.477z"
        />
      </g>
    </svg>
    """
  end

  def icon(%{name: "os-other"} = assigns) do
    ~H"""
    <.icon name="hero-computer-desktop" class={@class} {@rest} />
    """
  end

  @doc """
  Renders Gravatar img tag.
  """
  attr :email, :string, required: true
  attr :size, :integer, default: 40
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  def gravatar(assigns) do
    ~H"""
    <img
      src={"https://www.gravatar.com/avatar/#{Base.encode16(:crypto.hash(:md5, @email), case: :lower)}?s=#{@size}&d=retro"}
      {@rest}
    />
    """
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
      <%= render_slot(@empty) %>
    <% else %>
      <%= for item <- Enum.intersperse(@item, :separator) do %>
        <%= if item == :separator do %>
          <%= render_slot(@separator) %>
        <% else %>
          <%= render_slot(
            item,
            cond do
              item == List.first(@item) -> :first
              item == List.last(@item) -> :last
              true -> :middle
            end
          ) %>
        <% end %>
      <% end %>
    <% end %>
    """
  end

  @doc """
  Render children preview.

  Allows to render peeks into a schema preload by rendering a few of the children with a count of remaining ones.

  ## Examples

  ```heex
  <.peek>
    <:empty>
      nobody
    </:empty>

    <:item :let={item}>
      <%= item %>
    </:item>

    <:separator>
      ,
    </:separator>

    <:tail :let={count}>
      <%= count %> more.
    </:tail>
  </.peek>
  ```
  """
  attr :peek, :any,
    required: true,
    doc: "a tuple with the total number of items and items for a preview"

  slot :empty, required: false, doc: "the slots to render when there are no items"
  slot :item, required: true, doc: "the slots to intersperse with separators"
  slot :separator, required: false, doc: "the slot for the separator"
  slot :tail, required: true, doc: "the slots to render to show the remaining count"

  slot :call_to_action,
    required: false,
    doc: "the slot to render to show the call to action after the peek"

  def peek(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-y-2">
      <%= if Enum.empty?(@peek.items) do %>
        <%= render_slot(@empty) %>
      <% else %>
        <% items = if @separator, do: Enum.intersperse(@peek.items, :separator), else: @peek.items %>
        <%= for item <- items do %>
          <%= if item == :separator do %>
            <%= render_slot(@separator) %>
          <% else %>
            <%= render_slot(@item, item) %>
          <% end %>
        <% end %>

        <%= if @peek.count > length(@peek.items) do %>
          <%= render_slot(@tail, @peek.count - length(@peek.items)) %>
        <% end %>

        <%= render_slot(@call_to_action) %>
      <% end %>
    </div>
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
      <%= render_slot(@inner_block) %>
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
        <%= render_slot(@left) %>
      </div>
      <span class={[
        "text-xs",
        "rounded-r",
        "mr-2 py-0.5 pl-1.5 pr-2.5",
        @colors[@type]["light"]
      ]}>
        <%= render_slot(@right) %>
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
      <%= Cldr.DateTime.to_string!(@datetime, Web.CLDR, format: @format) %>
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

  def relative_datetime(assigns) do
    assigns =
      assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    ~H"""
    <.popover :if={not is_nil(@datetime)}>
      <:target>
        <span class={[
          "underline underline-offset-2 decoration-1 decoration-dotted",
          DateTime.compare(@datetime, @relative_to) == :lt && @negative_class
        ]}>
          <%= Cldr.DateTime.Relative.to_string!(@datetime, Web.CLDR, relative_to: @relative_to)
          |> String.capitalize() %>
        </span>
      </:target>
      <:content>
        <%= @datetime %>
      </:content>
    </.popover>
    <span :if={is_nil(@datetime)}>
      Never
    </span>
    """
  end

  @doc """
  Renders a popover element with title and content.
  """
  slot :target, required: true
  slot :content, required: true

  def popover(assigns) do
    # Any id will do
    target_id = "popover-#{System.unique_integer([:positive, :monotonic])}"
    assigns = assign(assigns, :target_id, target_id)

    ~H"""
    <span phx-hook="Popover" id={@target_id <> "-trigger"} data-popover-target-id={@target_id}>
      <%= render_slot(@target) %>
    </span>

    <div data-popover id={@target_id} role="tooltip" class={~w[
      absolute z-10 invisible inline-block
      text-sm text-neutral-500 transition-opacity
      duration-50 bg-white border border-neutral-200
      rounded shadow-sm opacity-0
      ]}>
      <div class="px-3 py-2">
        <%= render_slot(@content) %>
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
              "Last started #{Cldr.DateTime.Relative.to_string!(@schema.last_seen_at, Web.CLDR, relative_to: @relative_to)}",
            else: "Never connected"
        }
      >
        <%= if @schema.online?, do: "Online", else: "Offline" %>
      </span>
    </span>
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
  Renders creation timestamp and entity.
  """
  attr :account, :any, required: true
  attr :schema, :any, required: true

  def created_by(%{schema: %{created_by: :system}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} /> by system
    """
  end

  def created_by(%{schema: %{created_by: :actor}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} /> by
    <.actor_link account={@account} actor={@schema.created_by_actor} />
    """
  end

  def created_by(%{schema: %{created_by: :identity}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} /> by
    <.link
      class="text-accent-500 hover:underline"
      navigate={~p"/#{@schema.account_id}/actors/#{@schema.created_by_identity.actor.id}"}
    >
      <%= assigns.schema.created_by_identity.actor.name %>
    </.link>
    """
  end

  def created_by(%{schema: %{created_by: :provider}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} /> by
    <.link
      class="text-accent-500 hover:underline"
      navigate={Web.Settings.IdentityProviders.Components.view_provider(@account, @schema.provider)}
    >
      <%= @schema.provider.name %>
    </.link> sync
    """
  end

  @doc """
  Renders verification timestamp and entity.
  """
  attr :account, :any, required: true
  attr :schema, :any, required: true

  def verified_by(%{schema: %{verified_by: :system}} = assigns) do
    ~H"""
    <div class="flex items-center gap-x-1">
      <.icon name="hero-shield-check" class="w-4 h-4" /> Verified
      <.relative_datetime datetime={@schema.verified_at} /> by system
    </div>
    """
  end

  def verified_by(%{schema: %{verified_by: :actor}} = assigns) do
    ~H"""
    <div class="flex items-center gap-x-1">
      <.icon name="hero-shield-check" class="w-4 h-4" /> Verified
      <.relative_datetime datetime={@schema.verified_at} /> by
      <.actor_link account={@account} actor={@schema.verified_by_actor} />
    </div>
    """
  end

  def verified_by(%{schema: %{verified_by: :identity}} = assigns) do
    ~H"""
    <div class="flex items-center gap-x-1">
      <.icon name="hero-shield-check" class="w-4 h-4" /> Verified
      <.relative_datetime datetime={@schema.verified_at} /> by
      <.link
        class="text-accent-500 hover:underline"
        navigate={~p"/#{@schema.account_id}/actors/#{@schema.verified_by_identity.actor_id}"}
      >
        <%= assigns.schema.verified_by_actor.name %>
      </.link>
    </div>
    """
  end

  def verified_by(%{schema: %{verified_at: nil}} = assigns) do
    ~H"""
    Not Verified
    """
  end

  attr :account, :any, required: true
  attr :actor, :any, required: true

  def actor_link(%{actor: %Domain.Actors.Actor{type: :api_client}} = assigns) do
    ~H"""
    <.link class={link_style()} navigate={~p"/#{@account}/settings/api_clients/#{@actor}"}>
      <%= assigns.actor.name %>
    </.link>
    """
  end

  def actor_link(assigns) do
    ~H"""
    <.link class={link_style()} navigate={~p"/#{@account}/actors/#{@actor}"}>
      <%= assigns.actor.name %>
    </.link>
    """
  end

  attr :account, :any, required: true
  attr :identity, :any, required: true

  def identity_identifier(assigns) do
    ~H"""
    <span class="flex items-center" data-identity-id={@identity.id}>
      <.link
        navigate={
          Web.Settings.IdentityProviders.Components.view_provider(@account, @identity.provider)
        }
        data-provider-id={@identity.provider.id}
        title={"View identity provider \"#{@identity.provider.adapter}\""}
        class={~w[
          text-xs
          rounded-l
          py-0.5 px-1.5
          text-neutral-800
          bg-neutral-100
          border-neutral-100
          border
        ]}
      >
        <.provider_icon adapter={@identity.provider.adapter} class="h-3.5 w-3.5" />
      </.link>
      <span class={~w[
        text-xs
        min-w-0
        rounded-r
        mr-2 py-0.5 pl-1.5 pr-2.5
        text-neutral-900
        bg-neutral-50
      ]}>
        <span class="block truncate" title={get_identity_email(@identity)}>
          <%= get_identity_email(@identity) %>
        </span>
      </span>
    </span>
    """
  end

  def get_identity_email(identity) do
    Domain.Auth.get_identity_email(identity)
  end

  def identity_has_email?(identity) do
    Domain.Auth.identity_has_email?(identity)
  end

  attr :account, :any, required: true
  attr :group, :any, required: true
  attr :class, :string, default: nil

  def group(assigns) do
    ~H"""
    <span class={["flex items-center", @class]} data-group-id={@group.id}>
      <.link
        :if={Actors.group_synced?(@group)}
        navigate={Web.Settings.IdentityProviders.Components.view_provider(@account, @group.provider)}
        data-provider-id={@group.provider_id}
        title={"View identity provider \"#{@group.provider.adapter}\""}
        class={~w[
          rounded-l
          py-0.5 px-1.5
          text-neutral-800
          bg-neutral-100
          border-neutral-100
          border
        ]}
      >
        <.provider_icon adapter={@group.provider.adapter} class="h-3.5 w-3.5" />
      </.link>
      <div :if={not Actors.group_synced?(@group)} title="Manually managed in Firezone" class={~w[
          inline-flex
          rounded-l
          py-0.5 px-1.5
          text-neutral-800
          bg-neutral-100
          border-neutral-100
          border
        ]}>
        <.icon name="firezone" class="h-3.5 w-3.5" />
      </div>
      <.link
        title={"View Group \"#{@group.name}\""}
        navigate={~p"/#{@account}/groups/#{@group}"}
        class={~w[
          text-xs
          truncate
          min-w-0
          rounded-r pl-1.5 pr-2.5
          py-0.5
          text-neutral-900
          bg-neutral-50
        ]}
      >
        <%= @group.name %>
      </.link>
    </span>
    """
  end

  @doc """

  """
  attr :schema, :any, required: true

  def last_seen(assigns) do
    ~H"""
    <code class="text-xs -mr-1">
      <%= @schema.last_seen_remote_ip %>
    </code>
    <span class="text-neutral-500 inline-block text-xs">
      <%= [
        @schema.last_seen_remote_ip_location_region,
        @schema.last_seen_remote_ip_location_city
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ") %>

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
      <%= Web.CLDR.Number.Cardinal.pluralize(@number, :en, @opts) %>
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
      Gettext.dngettext(Web.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(Web.Gettext, "errors", msg, opts)
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
        <%= render_slot(@title) %>
      </h2>
      <div class="px-4">
        <%= render_slot(@content) %>
      </div>
    </div>
    """
  end

  @doc """
  Render an animated status indicator dot.
  """

  attr :color, :string, default: "info"

  def ping_icon(assigns) do
    ~H"""
    <span class="relative flex h-2.5 w-2.5">
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
  Renders a logo appropriate for the given provider.

  <.provider_icon adapter={:google_workspace} class="w-5 h-5 mr-2" />
  """
  attr :adapter, :atom, required: false
  attr :rest, :global

  def provider_icon(%{adapter: :google_workspace} = assigns) do
    ~H"""
    <img src={~p"/images/google-logo.svg"} alt="Google Workspace Logo" {@rest} />
    """
  end

  def provider_icon(%{adapter: :openid_connect} = assigns) do
    ~H"""
    <img src={~p"/images/openid-logo.svg"} alt="OpenID Connect Logo" {@rest} />
    """
  end

  def provider_icon(%{adapter: :microsoft_entra} = assigns) do
    ~H"""
    <img src={~p"/images/entra-logo.svg"} alt="Microsoft Entra Logo" {@rest} />
    """
  end

  def provider_icon(%{adapter: :okta} = assigns) do
    ~H"""
    <img src={~p"/images/okta-logo.svg"} alt="Okta Logo" {@rest} />
    """
  end

  def provider_icon(%{adapter: :jumpcloud} = assigns) do
    ~H"""
    <img src={~p"/images/jumpcloud-logo.svg"} alt="JumpCloud Logo" {@rest} />
    """
  end

  def provider_icon(%{adapter: :email} = assigns) do
    ~H"""
    <.icon name="hero-envelope" {@rest} />
    """
  end

  def provider_icon(%{adapter: :userpass} = assigns) do
    ~H"""
    <.icon name="hero-key" {@rest} />
    """
  end

  def provider_icon(assigns), do: ~H""

  def feature_name(%{feature: :idp_sync} = assigns) do
    ~H"""
    Automatically sync users and groups
    """
  end

  def feature_name(%{feature: :flow_activities} = assigns) do
    ~H"""
    See detailed Resource access logs
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

  def feature_name(%{feature: :self_hosted_relays} = assigns) do
    ~H"""
    Host your own Relays
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
end
