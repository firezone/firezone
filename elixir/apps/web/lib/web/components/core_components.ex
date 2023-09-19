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

  def logo(assigns) do
    ~H"""
    <a
      href="https://www.firezone.dev/?utm_source=product"
      class="flex items-center mb-6 text-2xl font-semibold"
    >
      <img src={~p"/images/logo.svg"} class="mr-3 h-8" alt="Firezone Logo" />
      <span class="self-center text-2xl font-semibold whitespace-nowrap dark:text-white">
        firezone
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
    <p class="text-gray-700 dark:text-gray-300"><%= render_slot(@inner_block) %></p>
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

  def code_block(assigns) do
    ~H"""
    <div id={@id} phx-hook="Copy" class={[~w[
      text-sm text-left sm:text-base text-white
      inline-flex items-center
      space-x-4 p-4 pl-6
      bg-gray-800
      relative
    ], @class]}>
      <code
        class="block  w-full no-scrollbar whitespace-nowrap overflow-x-auto rounded-b-lg"
        data-copy
      >
        <%= render_slot(@inner_block) %>
      </code>
      <.icon name="hero-clipboard-document" data-icon class={~w[
          absolute bottom-1 right-1
          h-5 w-5
          transition
          text-gray-500 group-hover:text-white
        ]} />
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
  end

  def tabs(assigns) do
    ~H"""
    <div class="mb-4">
      <div class="border-gray-200 dark:border-gray-700 bg-slate-50 rounded-t-lg">
        <ul
          class="flex flex-wrap text-sm font-medium text-center"
          id={"#{@id}-ul"}
          data-tabs-toggle={"##{@id}"}
          role="tablist"
        >
          <%= for tab <- @tab do %>
            <li class="mr-2" role="presentation">
              <button
                class={~w[
                inline-block p-4 border-b-2 border-transparent rounded-t-lg
                hover:text-gray-600 hover:border-gray-300 dark:hover:text-gray-300
              ]}
                id={"#{tab.id}-tab"}
                data-tabs-target={"##{tab.id}"}
                type="button"
                role="tab"
                aria-controls={tab.id}
                aria-selected="false"
              >
                <%= tab.label %>
              </button>
            </li>
          <% end %>
        </ul>
      </div>
      <div id={@id}>
        <%= for tab <- @tab do %>
          <div
            class="hidden rounded-b-lg bg-gray-50 dark:bg-gray-800"
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

  def header(assigns) do
    ~H"""
    <div class="grid grid-cols-1 p-4 xl:grid-cols-3 xl:gap-4 dark:bg-gray-900">
      <div class="col-span-full mb-4 xl:mb-2">
        <div class="flex justify-between items-center">
          <h1 class="text-xl font-semibold text-gray-900 sm:text-2xl dark:text-white">
            <%= render_slot(@title) %>
          </h1>
          <div class="inline-flex justify-between items-center space-x-2">
            <%= render_slot(@actions) %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a paginator bar.

  ## Examples

    <.paginator
      page={5}
      total_pages={100}
      collection_base_path={~p"/actors"}/>
  """
  attr :page, :integer, required: true, doc: "Current page"
  attr :total_pages, :integer, required: true, doc: "Total number of pages"
  attr :collection_base_path, :string, required: true, doc: "Base path for collection"

  def paginator(assigns) do
    # XXX: Stubbing out this pagination helper for now, but we probably won't have users that
    # need this at launch.
    ~H"""
    <nav
      class="flex flex-col md:flex-row justify-between items-start md:items-center space-y-3 md:space-y-0 p-4"
      aria-label="Table navigation"
    >
      <span class="text-sm font-normal text-gray-500 dark:text-gray-400">
        Showing <span class="font-semibold text-gray-900 dark:text-white">1-10</span>
        of <span class="font-semibold text-gray-900 dark:text-white">1000</span>
      </span>
      <ul class="inline-flex items-stretch -space-x-px">
        <li>
          <a href="#" class={~w[
              flex items-center justify-center h-full py-1.5 px-3 ml-0 text-gray-500 bg-white rounded-l-lg
              border border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            <span class="sr-only">Previous</span>
            <.icon name="hero-chevron-left" class="w-5 h-5" />
          </a>
        </li>
        <li>
          <a href="#" class={~w[
              flex items-center justify-center text-sm py-2 px-3 leading-tight text-gray-500 bg-white border
              border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            1
          </a>
        </li>
        <li>
          <a href="#" class={~w[
              flex items-center justify-center text-sm py-2 px-3 leading-tight text-gray-500 bg-white
              border border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            2
          </a>
        </li>
        <li>
          <a href="#" aria-current="page" class={~w[
              flex items-center justify-center text-sm z-10 py-2 px-3 leading-tight text-primary-600 bg-primary-50
              border border-primary-300 hover:bg-primary-100 hover:text-primary-700 dark:border-gray-700
              dark:bg-gray-700 dark:text-white
            ]}>
            <%= @page %>
          </a>
        </li>
        <li>
          <a href="#" class={~w[
              flex items-center justify-center text-sm py-2 px-3 leading-tight text-gray-500 bg-white
              border border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            ...
          </a>
        </li>
        <li>
          <a href="#" class={~w[
              flex items-center justify-center text-sm py-2 px-3 leading-tight text-gray-500 bg-white
              border border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            <%= @total_pages %>
          </a>
        </li>
        <li>
          <a href="#" class={~w[
              flex items-center justify-center h-full py-1.5 px-3 leading-tight text-gray-500 bg-white rounded-r-lg
              border border-gray-300 hover:bg-gray-100 hover:text-gray-700 dark:bg-gray-800 dark:border-gray-700
              dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-white
            ]}>
            <span class="sr-only">Next</span>
            <.icon name="hero-chevron-right" class="w-5 h-5" />
          </a>
        </li>
      </ul>
    </nav>
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
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
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
        @kind == :info && "text-yellow-800 bg-yellow-50 dark:bg-gray-800 dark:text-yellow-300",
        @kind == :error && "text-red-800 bg-red-50 dark:bg-gray-800 dark:text-red-400",
        @style != "wide" && "mb-4 rounded-lg"
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
    <label for={@for} class={["block mb-2 text-sm font-medium text-gray-900 dark:text-white", @class]}>
      <%= render_slot(@inner_block) %>
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  attr :rest, :global
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-3 flex gap-3 text-sm leading-6 text-rose-600 phx-no-feedback:hidden" {@rest}>
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
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
      class="mt-3 mb-3 flex gap-3 text-m leading-6 text-rose-600 phx-no-feedback:hidden"
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
      <dl class="-my-4 divide-y divide-zinc-100">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-zinc-500"><%= item.title %></dt>
          <dd class="text-zinc-700"><%= render_slot(item) %></dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a [Hero Icon](https://heroicons.com).

  Hero icons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid an mini may
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
  slot :separator, required: true, doc: "the slot for the separator"
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
          <%= render_slot(item) %>
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
      <% end %>
    </div>
    """
  end

  def status_page_widget(assigns) do
    ~H"""
    <div class="absolute bottom-0 left-0 justify-left p-4 space-x-4 w-full lg:flex bg-white dark:bg-gray-800 z-20">
      <.link href="https://firezone.statuspage.io" class="text-xs hover:underline">
        <span id="status-page-widget" phx-update="ignore" phx-hook="StatusPage" />
      </.link>
    </div>
    """
  end

  attr :type, :string, default: "default"
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    colors = %{
      "success" => "bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-300",
      "danger" => "bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-300",
      "warning" => "bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-300",
      "info" => "bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-300",
      "default" => "bg-gray-100 text-gray-800 dark:bg-gray-900 dark:text-gray-300"
    }

    assigns = assign(assigns, colors: colors)

    ~H"""
    <span
      class={[
        "text-xs font-medium mr-2 px-2.5 py-0.5 rounded whitespace-nowrap",
        @colors[@type],
        @class
      ]}
      {@rest}
    >
      <%= render_slot(@inner_block) %>
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

  def relative_datetime(assigns) do
    assigns = assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    ~H"""
    <span :if={not is_nil(@datetime)} title={@datetime}>
      <%= Cldr.DateTime.Relative.to_string!(@datetime, Web.CLDR, relative_to: @relative_to) %>
    </span>
    <span :if={is_nil(@datetime)}>
      never
    </span>
    """
  end

  @doc """
  Renders online or offline status using an `online?` field of the schema.
  """
  attr :schema, :any, required: true

  def connection_status(assigns) do
    assigns = assign_new(assigns, :relative_to, fn -> DateTime.utc_now() end)

    ~H"""
    <.badge
      type={if @schema.online?, do: "success", else: "danger"}
      title={
        if @schema.last_seen_at,
          do:
            "Last seen #{Cldr.DateTime.Relative.to_string!(@schema.last_seen_at, Web.CLDR, relative_to: @relative_to)}",
          else: "Never connected"
      }
    >
      <%= if @schema.online?, do: "Online", else: "Offline" %>
    </.badge>
    """
  end

  @doc """
  Renders creation timestamp and entity.
  """
  attr :account, :any, required: true
  attr :schema, :any, required: true

  def created_by(%{schema: %{created_by: :system}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} />
    """
  end

  def created_by(%{schema: %{created_by: :identity}} = assigns) do
    ~H"""
    <.relative_datetime datetime={@schema.inserted_at} /> by
    <.link
      class="text-blue-600 hover:underline"
      navigate={~p"/#{@schema.account_id}/actors/#{@schema.created_by_identity.actor.id}"}
    >
      <%= assigns.schema.created_by_identity.actor.name %>
    </.link>
    """
  end

  def created_by(%{schema: %{created_by: :provider}} = assigns) do
    ~H"""
    synced <.relative_datetime datetime={@schema.inserted_at} /> from
    <.link
      class="text-blue-600 hover:underline"
      navigate={Web.Settings.IdentityProviders.Components.view_provider(@account, @schema.provider)}
    >
      <%= @schema.provider.name %>
    </.link>
    """
  end

  attr :account, :any, required: true
  attr :identity, :any, required: true

  def identity_identifier(assigns) do
    ~H"""
    <span class="flex inline-flex" data-identity-id={@identity.id}>
      <.link
        navigate={
          Web.Settings.IdentityProviders.Components.view_provider(@account, @identity.provider)
        }
        data-provider-id={@identity.provider.id}
        title={@identity.provider.adapter}
        class={~w[
          text-xs font-medium
          rounded-l
          py-0.5 pl-2.5 pr-1.5
          text-blue-800 dark:text-blue-300
          bg-blue-100 dark:bg-blue-900]}
      >
        <%= @identity.provider.name %>
      </.link>
      <span class={[
        "text-xs font-medium",
        "rounded-r",
        "mr-2 py-0.5 pl-1.5 pr-2.5",
        "text-blue-800 dark:text-blue-300",
        "bg-blue-50 dark:bg-blue-600"
      ]}>
        <%= get_in(@identity.provider_state, ["userinfo", "email"]) || @identity.provider_identifier %>
      </span>
      <span :if={not is_nil(@identity.deleted_at)} class="text-sm">
        (deleted)
      </span>
      <span :if={not is_nil(@identity.provider.disabled_at)} class="text-sm">
        (provider disabled)
      </span>
      <span :if={not is_nil(@identity.provider.deleted_at)} class="text-sm">
        (provider deleted)
      </span>
    </span>
    """
  end

  attr :account, :any, required: true
  attr :group, :any, required: true

  def group(assigns) do
    ~H"""
    <span class="inline-block whitespace-nowrap mr-2" data-group-id={@group.id}>
      <.link
        :if={Actors.group_synced?(@group)}
        navigate={Web.Settings.IdentityProviders.Components.view_provider(@account, @group.provider)}
        data-provider-id={@group.provider_id}
        title={@group.provider.adapter}
        class={[
          "text-xs font-medium",
          "rounded-l",
          "py-0.5 pl-2.5 pr-1.5",
          "text-blue-800 dark:text-blue-300",
          "bg-blue-100 dark:bg-blue-900",
          "whitespace-nowrap"
        ]}
      >
        <%= @group.provider.name %>
      </.link>
      <.link
        navigate={~p"/#{@account}/groups/#{@group}"}
        class={[
          "text-xs font-medium",
          if(Actors.group_synced?(@group), do: "rounded-r pl-1.5 pr-2.5", else: "rounded px-1.5"),
          "py-0.5",
          "text-blue-800 dark:text-blue-300",
          "bg-blue-50 dark:bg-blue-600",
          "whitespace-nowrap"
        ]}
      >
        <%= @group.name %>
      </.link>
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
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
