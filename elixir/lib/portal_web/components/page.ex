defmodule PortalWeb.Components.Page do
  use Phoenix.Component
  use PortalWeb, :verified_routes
  alias PortalWeb.Components.Core

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
      <div class="flex flex-wrap items-center justify-between gap-2 mb-1">
        <legend class="block text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
          Permissions
        </legend>

        <div class="flex items-center gap-2 text-xs">
          <.scope_preset_button preset="none">Select none</.scope_preset_button>
          <span class="text-faint">·</span>
          <.scope_preset_button preset="read">Select read-only</.scope_preset_button>
          <span class="text-faint">·</span>
          <.scope_preset_button preset="all">Select all</.scope_preset_button>
        </div>
      </div>

      <p class="mb-3 text-xs text-muted">
        Always allow only the minimum permissions you need for this integration.
      </p>
      <!-- Submits the key even when nothing is ticked. -->
      <input type="hidden" name={@field_name} value="" />

      <div class={[
        "border-t",
        (@error && "border-attn") || "border-rule"
      ]}>
        <div class="flex items-center py-2 border-b border-rule">
          <span class="flex-1 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Scope
          </span>
          <span class="w-16 text-center text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Read
          </span>
          <span class="w-16 text-center text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
            Write
          </span>
        </div>

        <div :for={{entity, levels} <- @entities} class="flex items-center py-2.5 border-b border-hair">
          <div class="flex-1 pr-4">
            <span class="block text-sm text-fg">{Portal.Scope.label(entity)}</span>
            <span class="block text-xs text-muted">{Portal.Scope.description(entity)}</span>
          </div>

          <span :for={level <- [:read, :write]} class="w-16 flex justify-center">
            <input
              :if={level in levels}
              type="checkbox"
              name={@field_name}
              value={Portal.Scope.to_string(entity, level)}
              checked={scope_checked?(@scopes, entity, level)}
              disabled={scope_locked?(@scopes, entity, level)}
              class="w-4 h-4 bg-bg text-fg border-rule focus:ring-fg disabled:opacity-50"
            />
          </span>
        </div>
      </div>

      <p :if={@error} class="mt-2 flex items-center gap-2 text-sm text-attn">
        <Core.icon name="ri-error-warning-line" class="h-4 w-4 flex-none" />{@error}
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
      class="font-medium text-fg underline underline-offset-[3px] decoration-faint hover:decoration-fg"
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
    <div class="mb-8 border border-rule px-4 py-4">
      <div class="flex items-center gap-3">
        <.client_icon client={@client} class="w-11 h-11" />

        <div class="min-w-0">
          <p class="text-base font-semibold text-fg truncate">
            {@client.client_name}
          </p>
          <p class="text-sm text-muted">wants to connect to Firezone</p>
        </div>
      </div>

      <div class="mt-4 pt-3 border-t border-hair">
        <p class="mb-1.5 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
          Verified address
        </p>

        <p class="flex items-center gap-2">
          <Core.icon name="ri-lock-line" class="w-4 h-4 text-fg shrink-0" />
          <span class="text-base font-semibold font-mono text-fg break-all">
            {client_host(@client.client_id)}
          </span>
        </p>

        <div :if={@client.resolved_ips != []} class="mt-1.5 text-xs text-muted">
          <p>Served from</p>
          <ul class="mt-1 space-y-1">
            <li :for={ip <- @client.resolved_ips} class="break-all">
              <span class="font-mono">{to_string(ip)}</span>{origin_location(ip)}
            </li>
          </ul>
        </div>
      </div>

      <p class="mt-3 text-xs text-muted leading-relaxed">
        Only this address is checked. The name and icon are supplied by the app
        itself. If you do not recognize it, close this window.
      </p>
    </div>
    """
  end

  defp origin_location(%Postgrex.INET{address: address}) do
    case Portal.Geo.locate(address, []) do
      {nil, nil, _coordinates} -> " · Location unavailable"
      {region, nil, _coordinates} -> " · #{region}"
      {nil, city, _coordinates} -> " · #{city}"
      {region, city, _coordinates} -> " · #{city}, #{region}"
    end
  end

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
      "border border-hair bg-bg overflow-hidden flex items-center justify-center shrink-0",
      @class
    ]}>
      <img
        :if={@src}
        src={@src}
        alt={@client.client_name}
        class="w-full h-full object-contain"
      />
      <span :if={is_nil(@src)} class="text-xl font-bold text-fg">
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
    <div class="pt-2">
      <p class="mb-1.5 text-xs font-medium text-muted">
        Your organization's sign-in URL
      </p>
      <.form :let={f} for={%{}} action={@action}>
        <div class="flex gap-2">
          <%!-- One box: the host is plain text in front of the input, and clicking it focuses the input --%>
          <label class="flex flex-1 min-w-0 h-10 items-center border border-rule bg-bg cursor-text focus-within:ring-1 focus-within:ring-fg transition-colors">
            <span
              id="account-slug-host"
              class="pl-3 font-mono text-sm text-muted whitespace-nowrap select-none"
            >
              {portal_base_url()}/
            </span>
            <input
              type="text"
              name={f[:account_id_or_slug].name}
              placeholder="acme_corp"
              aria-label="Organization sign-in URL"
              aria-describedby="account-slug-host"
              autofocus={@autofocus}
              required
              class="flex-1 min-w-0 pl-0 pr-3 py-2 font-mono text-sm bg-transparent border-0 text-fg outline-none focus:outline-none focus:ring-0 placeholder:text-faint"
            />
          </label>
          <button
            type="submit"
            class="inline-flex items-center gap-2 h-10 px-4 text-sm font-semibold whitespace-nowrap bg-fg text-bg border border-fg hover:opacity-85 transition-opacity"
          >
            Continue <Core.icon name="ri-arrow-right-line" class="w-4 h-4" />
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # The portal's public URL as people see it in the address bar, e.g. "https://app.firezone.dev".
  # Uses the configured URL rather than the request, since the portal sits behind a proxy.
  defp portal_base_url do
    case PortalWeb.Endpoint.struct_url() do
      %URI{scheme: "https", host: host, port: port} when port in [nil, 443] -> "https://#{host}"
      %URI{scheme: "http", host: host, port: port} when port in [nil, 80] -> "http://#{host}"
      %URI{scheme: scheme, host: host, port: port} -> "#{scheme}://#{host}:#{port}"
    end
  end

  @doc """
  One account in a list of accounts to choose between.

  Shared by the sign-in chooser and the OAuth consent flow, which send the
  person to different places, so the destination is passed in.
  """
  attr :account, :any, required: true
  attr :href, :string, required: true
  attr :arrow, :boolean, default: true, doc: "whether to show the chevron on the right"
  attr :class, :any, default: nil

  def account_button(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "group w-full flex items-center gap-3 px-4 py-3 border border-rule bg-bg hover:bg-hover transition-colors",
        "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-fg",
        @class
      ]}
    >
      <div class="w-9 h-9 flex items-center justify-center shrink-0 bg-fg text-bg">
        <span class="text-sm font-bold">
          {String.upcase(String.first(@account.name))}
        </span>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-semibold text-fg truncate">{@account.name}</p>
        <p class="text-xs font-mono text-muted truncate">{@account.slug}</p>
      </div>
      <Core.icon
        :if={@arrow}
        name="ri-arrow-right-line"
        class="w-4 h-4 text-muted group-hover:text-fg group-hover:translate-x-0.5 transition-transform shrink-0"
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
        "mb-8 mx-6 bg-bg",
        @content != [] && "pb-2"
      ]}
    >
      <Core.header>
        <:title>
          {render_slot(@title)}
        </:title>

        <:actions :for={action <- @action} :if={not Enum.empty?(@action)}>
          {render_slot(action)}
        </:actions>

        <:help :for={help <- @help} :if={not Enum.empty?(@help)}>
          {render_slot(help)}
        </:help>
      </Core.header>

      <section :for={content <- @content} class="section-body">
        <div :if={Map.get(content, :flash)} class="mb-4">
          <Core.flash kind={:info} flash={Map.get(content, :flash)} style="wide" />
          <Core.flash kind={:error} flash={Map.get(content, :flash)} style="wide" />
        </div>
        {render_slot(content)}
      </section>
    </div>
    """
  end

  @doc """
  Renders the modal that shows one item's details, or a form, over the page.

  Every list page opens its items in this, so there is one pattern across the
  portal: the list stays put behind a veil, the item opens on top, and Escape or
  a click on the veil closes it.

  The wrapper stays in the DOM while closed (hidden and empty), so it keeps the
  same element id whether it is open or not.

  ## Examples

      <Page.detail_modal id="resource-panel" open={@selected != nil} on_close="close_panel">
        ...
      </Page.detail_modal>
  """
  attr :id, :string, required: true
  attr :open, :boolean, required: true
  attr :on_close, :any, required: true, doc: "event name or JS run on Escape and veil clicks"
  attr :size, :string, default: "lg", values: ~w[md lg xl]
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def detail_modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "fixed inset-0 z-40 items-start justify-center px-4 pt-[5vh] pb-6",
        if(@open, do: "flex", else: "hidden")
      ]}
      phx-window-keydown={@open && @on_close}
      phx-key="Escape"
      {@rest}
    >
      <div
        :if={@open}
        id={"#{@id}-veil"}
        class="absolute inset-0 bg-veil backdrop-blur-[1px]"
        phx-click={@on_close}
        aria-hidden="true"
      >
      </div>
      <div
        :if={@open}
        role="dialog"
        aria-modal="true"
        class={[
          "relative flex flex-col w-full max-h-[90vh] overflow-hidden",
          "bg-bg text-fg border border-rule shadow-lg",
          @size == "md" && "max-w-2xl",
          @size == "lg" && "max-w-4xl",
          @size == "xl" && "max-w-6xl",
          @class
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a page header with icon, title, description, action, and stats slots.

  ## Examples

      <Page.page_header>
        <:icon><Core.icon name="ri-server-line" class="w-8 h-8 text-brand" /></:icon>
        <:title>Resources</:title>
        <:description>Network endpoints accessible through Firezone.</:description>
        <:action>
          <Form.add_button navigate={~p"/resources/new"}>Add Resource</Form.add_button>
        </:action>
        <:stats>
          <Core.dual_badge type="primary">
            <:left>{@resources_count}</:left>
            <:right>Total</:right>
          </Core.dual_badge>
        </:stats>
      </Page.page_header>
  """
  slot :icon, required: false, doc: "Large icon displayed beside the title"
  slot :title, required: true, doc: "The page title"
  slot :description, required: false, doc: "Short description below the title"
  slot :action, required: false, doc: "Action button(s) shown in the top-right"
  slot :stats, required: false, doc: "Count badges or other stats shown below the title row"

  def page_header(assigns) do
    ~H"""
    <div class="px-6 pt-7 pb-5 bg-bg shrink-0">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:gap-4">
        <div class="min-w-0">
          <h1 class="flex items-center gap-3 text-[26px] leading-tight font-bold tracking-tight text-fg">
            {render_slot(@title)}
            <span
              :if={not Enum.empty?(@stats)}
              class="text-sm font-normal tracking-normal text-muted tabular-nums"
            >
              {render_slot(@stats)}
            </span>
          </h1>
          <p :if={not Enum.empty?(@description)} class="hidden md:block mt-1 text-sm text-muted">
            {render_slot(@description)}
          </p>
        </div>
        <div :if={not Enum.empty?(@action)} class="sm:ml-auto shrink-0 flex items-center gap-2">
          {render_slot(@action)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The Firezone Cloud region this portal keeps its data in, or `:on_prem`.
  """
  def data_residency_region, do: Portal.Config.fetch_env!(:portal, :data_residency_region)

  def data_residency_name(:us), do: "United States"
  def data_residency_name(:eu), do: "European Union"

  # The primary database and its read replica, from the db workspaces in the
  # infra repository.
  def data_residency_locations(:us), do: [{"Iowa", "United States"}, {"Arizona", "United States"}]
  def data_residency_locations(:eu), do: [{"Gävle", "Sweden"}, {"Paris", "France"}]

  def other_region(:us), do: :eu
  def other_region(:eu), do: :us

  @doc """
  The flag of a data residency region, drawn inline so it looks the same on
  every platform (Windows has no flag emoji).
  """
  attr :region, :atom, required: true
  attr :class, :string, default: "w-5 h-auto"

  def residency_flag(%{region: :us} = assigns) do
    ~H"""
    <svg
      class={["shrink-0 rounded-[2px]", @class]}
      viewBox="0 0 19 10"
      role="img"
      aria-label="United States flag"
    >
      <rect width="19" height="10" fill="#b22234" />
      <path
        d="M0 1.15h19M0 2.69h19M0 4.23h19M0 5.77h19M0 7.31h19M0 8.85h19"
        stroke="#fff"
        stroke-width="0.77"
      />
      <rect width="7.6" height="5.38" fill="#3c3b6e" />
    </svg>
    """
  end

  def residency_flag(%{region: :eu} = assigns) do
    ~H"""
    <svg
      class={["shrink-0 rounded-[2px]", @class]}
      viewBox="0 0 30 20"
      role="img"
      aria-label="European Union flag"
    >
      <rect width="30" height="20" fill="#003399" />
      <circle
        :for={i <- 0..11}
        cx="15"
        cy="4"
        r="0.9"
        fill="#ffcc00"
        transform={"rotate(#{i * 30} 15 10)"}
      />
    </svg>
    """
  end

  @firezone_cloud_urls %{us: "https://app.firezone.dev", eu: "https://eu.app.firezone.dev"}
  @firezone_api_urls %{us: "wss://api.firezone.dev", eu: "wss://eu.api.firezone.dev"}

  @doc "The admin portal URL of a Firezone Cloud region."
  def portal_url(region), do: Map.fetch!(@firezone_cloud_urls, region)

  @doc "The control plane API URL of a Firezone Cloud region."
  def api_url(region), do: Map.fetch!(@firezone_api_urls, region)

  @doc "The portal URL of a Firezone Cloud region, by atom or by its name in the slug registry."
  @spec cloud_url(atom() | String.t()) :: {:ok, String.t()} | :error
  def cloud_url("us"), do: cloud_url(:us)
  def cloud_url("eu"), do: cloud_url(:eu)
  def cloud_url(region) when is_atom(region), do: Map.fetch(@firezone_cloud_urls, region)
  def cloud_url(_region), do: :error

  @doc """
  Whether this portal is the production Firezone Cloud portal for its region,
  rather than staging or a local portal configured with the same region.
  """
  def firezone_cloud?(region) do
    case Map.fetch(@firezone_cloud_urls, region) do
      {:ok, url} ->
        URI.parse(url).host ==
          URI.parse(Portal.Config.get_env(:portal, :web_external_url) || "").host

      :error ->
        false
    end
  end

  @doc """
  Shows which region the portal keeps its data in, at the bottom of the sign in
  pages. The Firezone Cloud portals also link to the other region's portal, at
  the same page unless the page belongs to an account. On-prem portals show
  nothing.
  """
  attr :path, :string, default: nil, doc: "The current path and query string"

  def data_residency_footer(assigns) do
    region = data_residency_region()

    assigns =
      assigns
      |> assign(:region, region)
      |> assign(:show_other_region, firezone_cloud?(region))

    ~H"""
    <p
      :if={@region != :on_prem}
      id="data-residency"
      class="flex flex-wrap items-center justify-center gap-1.5 mt-8 pt-4 border-t border-hair text-xs text-muted"
    >
      <.residency_flag region={@region} class="w-5 h-auto" />
      <span>Cloud region: <strong>{data_residency_name(@region)}</strong></span>
      <span :if={@show_other_region} aria-hidden="true">&middot;</span>
      <a
        :if={@show_other_region}
        id="other-region-portal"
        href={other_region_portal_url(@region, @path)}
        class="hover:underline"
      >
        Go to the {other_region_short_name(@region)} portal &rarr;
      </a>
    </p>
    """
  end

  defp other_region_short_name(:us), do: "EU"
  defp other_region_short_name(:eu), do: "US"

  defp other_region_portal_url(region, path) do
    base = Map.fetch!(@firezone_cloud_urls, other_region(region))

    if path && not account_scoped?(path), do: base <> path, else: base
  end

  # Accounts live in one region, so their pages don't exist in the other one.
  defp account_scoped?(path) do
    case Phoenix.Router.route_info(PortalWeb.Router, "GET", URI.parse(path).path, nil) do
      %{path_params: path_params} -> Map.has_key?(path_params, "account_id_or_slug")
      :error -> true
    end
  end
end
