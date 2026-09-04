defmodule PortalWeb.PageComponents do
  use Phoenix.Component
  use PortalWeb, :verified_routes
  import PortalWeb.CoreComponents

  @doc """
  The read/write permission picker.

  Shared by the API token form and the OAuth consent screen so the two always
  look and behave the same. Both are LiveViews, so the shortcut buttons are
  `phx-click` events and the server stays the source of truth for what is
  ticked. They post to different fields, which is what `field_name` is for.
  """
  attr :scopes, :list, required: true, doc: "The scopes currently selected"
  attr :allowed_scopes, :list, default: nil, doc: "The scopes that may be selected"
  attr :field_name, :string, required: true, doc: "Name for each checkbox"
  attr :error, :string, default: nil

  def scope_picker(assigns) do
    assigns = assign(assigns, :entities, sorted_scope_entities(assigns.allowed_scopes))

    ~H"""
    <fieldset>
      <div class="flex items-center justify-between mb-1">
        <legend class="block text-xs font-medium text-body">Permissions</legend>

        <div class="flex items-center gap-2 text-xs">
          <.scope_preset_button preset="none">Select none</.scope_preset_button>
          <span class="text-subtle">·</span>
          <.scope_preset_button preset="read">Select read-only</.scope_preset_button>
          <span class="text-subtle">·</span>
          <.scope_preset_button preset="all">Select all</.scope_preset_button>
        </div>
      </div>

      <p class="mb-3 text-xs text-subtle">
        Always allow only the minimum permissions you need for this integration.
      </p>
      <!-- Submits the key even when nothing is ticked. -->
      <input type="hidden" name={@field_name} value="" />

      <div class={[
        "rounded border divide-y divide-border",
        (@error && "border-error ring-1 ring-error/30") || "border-border"
      ]}>
        <div class="flex items-center px-3 py-2 bg-raised">
          <span class="flex-1 text-xs font-medium text-subtle">Scope</span>
          <span class="w-16 text-center text-xs font-medium text-subtle">Read</span>
          <span class="w-16 text-center text-xs font-medium text-subtle">Write</span>
        </div>

        <div :for={{entity, levels} <- @entities} class="flex items-center px-3 py-2">
          <div class="flex-1 pr-4">
            <span class="block text-sm text-heading">{Portal.Scope.label(entity)}</span>
            <span class="block text-xs text-subtle">{Portal.Scope.description(entity)}</span>
          </div>

          <span :for={level <- [:read, :write]} class="w-16 flex justify-center">
            <input
              :if={level in levels}
              type="checkbox"
              name={@field_name}
              value={Portal.Scope.to_string(entity, level)}
              checked={scope_checked?(@scopes, entity, level)}
              disabled={scope_locked?(@scopes, entity, level)}
              class="w-4 h-4 text-brand border-border rounded disabled:opacity-50"
            />
          </span>
        </div>
      </div>

      <p :if={@error} class="mt-2 flex items-center gap-2 text-sm text-error">
        <.icon name="ri-alert-line" class="h-4 w-4 flex-none" />{@error}
      </p>
    </fieldset>
    """
  end

  attr :preset, :string, required: true
  slot :inner_block, required: true

  defp scope_preset_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_scopes"
      phx-value-preset={@preset}
      class="text-brand hover:underline"
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp sorted_scope_entities(allowed_scopes) do
    allowed_scopes = allowed_scopes && Portal.Scope.expand(allowed_scopes)

    Portal.Scope.levels_by_entity()
    |> Enum.map(fn {entity, levels} ->
      levels =
        if allowed_scopes do
          Enum.filter(levels, &(Portal.Scope.to_string(entity, &1) in allowed_scopes))
        else
          levels
        end

      {entity, levels}
    end)
    |> Enum.reject(fn {_entity, levels} -> levels == [] end)
    |> Enum.sort_by(fn {entity, _levels} ->
      Portal.Scope.label(entity)
    end)
  end

  defp scope_checked?(scopes, entity, :read) do
    Portal.Scope.to_string(entity, :read) in scopes or
      Portal.Scope.to_string(entity, :write) in scopes
  end

  defp scope_checked?(scopes, entity, level),
    do: Portal.Scope.to_string(entity, level) in scopes

  # A locked box submits nothing, which is why scopes are expanded on read-back.
  defp scope_locked?(scopes, entity, :read),
    do: Portal.Scope.to_string(entity, :write) in scopes

  defp scope_locked?(_scopes, _entity, _level), do: false

  @doc """
  The identity of the app being connected, shown at the top of every screen in
  the OAuth flow so it never changes underneath the person deciding.

  Only the address is verified: it is the host the metadata document was fetched
  from over TLS, and the redirect the code is sent to has to be listed in that
  document. The name and icon come out of that document, so they are whatever
  the app chose to say about itself and are given less weight here.
  """
  attr :client, :any, required: true

  def oauth_client_header(assigns) do
    ~H"""
    <div class="mb-8 rounded border border-border bg-raised px-4 py-4">
      <div class="flex items-center gap-3">
        <.client_icon client={@client} class="w-11 h-11" />

        <div class="min-w-0">
          <p class="text-base font-semibold text-heading truncate">
            {@client.client_name}
          </p>
          <p class="text-sm text-body">wants to connect to Firezone</p>
        </div>
      </div>

      <div class="mt-3 pt-3 border-t border-border">
        <p class="text-xs font-medium text-subtle uppercase tracking-wide mb-1.5">
          Verified address
        </p>

        <p class="flex items-center gap-2">
          <.icon name="ri-lock-line" class="w-4 h-4 text-brand shrink-0" />
          <span class="text-base font-semibold font-mono text-heading break-all">
            {client_host(@client.client_id)}
          </span>
        </p>

        <p :if={@client.resolved_ips != []} class="mt-1.5 text-xs font-mono text-subtle break-all">
          Served from {Enum.map_join(@client.resolved_ips, ", ", &to_string/1)}{origin_location(
            @client
          )}
        </p>
      </div>

      <p class="mt-3 text-xs text-subtle leading-relaxed">
        Only this address is checked. The name and icon are supplied by the app
        itself. If you do not recognise it, close this window.
      </p>
    </div>
    """
  end

  defp origin_location(%{resolved_ip_location_region: nil}), do: ""

  defp origin_location(%{resolved_ip_location_region: region, resolved_ip_location_city: nil}),
    do: " · #{region}"

  defp origin_location(%{resolved_ip_location_region: region, resolved_ip_location_city: city}),
    do: " · #{city}, #{region}"

  @doc """
  The tile identifying an OAuth client by its icon, falling back to its initial.

  The icon was fetched once when the client's metadata document was, so it is
  inlined here rather than hotlinked: the page makes no request to the client
  and the content security policy needs no exception for its host.
  """
  attr :client, :any, required: true
  attr :class, :string, default: "w-14 h-14"

  def client_icon(assigns) do
    assigns = assign(assigns, :src, client_icon_src(assigns.client))

    ~H"""
    <div class={[
      "rounded-xl border border-border bg-surface overflow-hidden flex items-center justify-center shrink-0",
      @class
    ]}>
      <img
        :if={@src}
        src={@src}
        alt={@client.client_name}
        class="w-full h-full object-contain"
      />
      <span :if={is_nil(@src)} class="text-xl font-bold text-brand">
        {String.upcase(String.first(@client.client_name))}
      </span>
    </div>
    """
  end

  @doc """
  The origin an OAuth client's metadata document was fetched from.

  This is the part of a client's identity that is actually checked. The name and
  any logo come from that document and are whatever the client chose to put in
  it, so the host is what a person should be reading.
  """
  def client_host(client_id) do
    case URI.parse(client_id) do
      %URI{host: host} when is_binary(host) -> host
      _other -> client_id
    end
  end

  defp client_icon_src(%{logo_data: data, logo_content_type: type})
       when is_binary(data) and is_binary(type) do
    "data:#{type};base64,#{Base.encode64(data)}"
  end

  defp client_icon_src(_client), do: nil

  @doc """
  The card for entering an account slug when it is not in the recent list.

  Shared by the sign-in chooser and the OAuth consent flow, which post to
  different places.
  """
  attr :action, :string, required: true
  attr :autofocus, :boolean, default: false

  def account_slug_form(assigns) do
    ~H"""
    <div class="rounded border border-border bg-raised p-4">
      <p class="text-xs font-semibold text-body mb-3">
        Enter your organization's account slug or ID below
      </p>
      <.form :let={f} for={%{}} action={@action}>
        <div class="flex gap-2">
          <input
            type="text"
            name={f[:account_id_or_slug].name}
            placeholder="e.g. acme_corp"
            autofocus={@autofocus}
            required
            class="flex-1 px-3 py-2 text-sm rounded border bg-input border-input-border text-heading outline-none focus:border-border-focus focus:ring-1 focus:ring-border-focus/30 transition-colors placeholder:text-muted"
          />
          <button
            type="submit"
            class="px-4 py-2 rounded text-sm font-semibold bg-brand text-white hover:bg-brand-dark transition-colors whitespace-nowrap"
          >
            Continue →
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @doc """
  One account in a list of accounts to choose between.

  Shared by the sign-in chooser and the OAuth consent flow, which send the
  person to different places, so the destination is passed in.
  """
  attr :account, :any, required: true
  attr :href, :string, required: true

  def account_button(assigns) do
    ~H"""
    <a
      href={@href}
      class="w-full flex items-center gap-3 px-4 py-3 rounded border-2 border-border bg-surface hover:border-brand hover:shadow-sm transition-all duration-150 group"
    >
      <div class="w-9 h-9 rounded bg-brand/10 flex items-center justify-center shrink-0 group-hover:bg-brand/20 transition-colors">
        <span class="text-sm font-bold text-brand">
          {String.upcase(String.first(@account.name))}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold text-heading group-hover:text-brand transition-colors truncate">
          {@account.name}
        </p>
        <p class="text-xs text-subtle truncate">{@account.slug}</p>
      </div>
      <.icon
        name="ri-arrow-right-s-line"
        class="w-5.5 h-5.5 text-muted group-hover:text-brand group-hover:translate-x-0.5 transition-all shrink-0"
      />
    </a>
    """
  end

  attr :id, :string, default: nil, doc: "The id of the section"
  slot :title, required: true, doc: "The title of the section to be displayed"
  slot :action, required: false, doc: "A slot for action to the right from title"

  slot :content, required: true, doc: "A slot for content of the section" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  slot :help, required: false, doc: "A slot for help text to be displayed above the content"

  def section(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "mb-4 md:mb-6 bg-surface mx-2 md:mx-5 border border-border px-4 md:px-6",
        @content != [] && "pb-6"
      ]}
    >
      <.header>
        <:title>
          {render_slot(@title)}
        </:title>

        <:actions :for={action <- @action} :if={not Enum.empty?(@action)}>
          {render_slot(action)}
        </:actions>

        <:help :for={help <- @help} :if={not Enum.empty?(@help)}>
          {render_slot(help)}
        </:help>
      </.header>

      <section :for={content <- @content} class="section-body">
        <div :if={Map.get(content, :flash)} class="mb-4">
          <.flash kind={:info} flash={Map.get(content, :flash)} style="wide" />
          <.flash kind={:error} flash={Map.get(content, :flash)} style="wide" />
        </div>
        {render_slot(content)}
      </section>
    </div>
    """
  end

  slot :action, required: false, doc: "A slot for action to the right of the title"

  slot :content, required: false, doc: "A slot for content of the section" do
    attr :flash, :any, doc: "The flash to be displayed above the content"
  end

  def danger_zone(assigns) do
    ~H"""
    <.section :if={length(@action) > 0}>
      <:title>Danger Zone</:title>

      <:action :for={action <- @action} :if={not Enum.empty?(@action)}>
        {render_slot(action)}
      </:action>

      <:content :for={content <- @content}>
        {render_slot(content)}
      </:content>
    </.section>
    """
  end

  @doc """
  Renders a page header with icon, title, description, action, and stats slots.

  ## Examples

      <.page_header>
        <:icon><.icon name="ri-server-line" class="w-8 h-8 text-brand" /></:icon>
        <:title>Resources</:title>
        <:description>Network endpoints accessible through Firezone.</:description>
        <:action>
          <.add_button navigate={~p"/resources/new"}>Add Resource</.add_button>
        </:action>
        <:stats>
          <.dual_badge type="primary">
            <:left>{@resources_count}</:left>
            <:right>Total</:right>
          </.dual_badge>
        </:stats>
      </.page_header>
  """
  slot :icon, required: false, doc: "Large icon displayed beside the title"
  slot :title, required: true, doc: "The page title"
  slot :description, required: false, doc: "Short description below the title"
  slot :action, required: false, doc: "Action button(s) shown in the top-right"
  slot :stats, required: false, doc: "Count badges or other stats shown below the title row"

  def page_header(assigns) do
    ~H"""
    <div class="relative overflow-hidden px-4 pt-4 pb-3 md:px-6 md:pt-6 md:pb-4 border-b border-border bg-surface">
      <div class="absolute inset-x-0 top-0 h-[2px] bg-brand opacity-50"></div>
      <div class="flex items-start gap-5">
        <div :if={not Enum.empty?(@icon)} class="hidden md:block shrink-0 mt-0.5">
          {render_slot(@icon)}
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
            <div class="min-w-0">
              <h1 class="text-base font-semibold text-heading">
                {render_slot(@title)}
              </h1>
              <p
                :if={not Enum.empty?(@description)}
                class="hidden md:block mt-0.5 text-sm text-body"
              >
                {render_slot(@description)}
              </p>
            </div>
            <div :if={not Enum.empty?(@action)} class="shrink-0 flex items-center gap-2">
              {render_slot(@action)}
            </div>
          </div>
          <div :if={not Enum.empty?(@stats)} class="mt-2 flex items-center gap-2 flex-wrap">
            {render_slot(@stats)}
          </div>
        </div>
      </div>
    </div>
    """
  end
end
