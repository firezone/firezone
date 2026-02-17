defmodule PortalWeb.Dashboard do
  use PortalWeb, :live_view

  alias Portal.Billing
  alias Portal.Dashboard
  alias Portal.Presence
  alias Portal.PubSub

  def mount(_params, _session, socket) do
    account_id = socket.assigns.account.id

    if connected?(socket) do
      :ok = Presence.Gateways.Account.subscribe(account_id)
      :ok = Presence.Clients.Account.subscribe(account_id)
      :ok = PubSub.PolicyAuthorizations.subscribe(account_id)
    end

    subject = socket.assigns.subject

    stats = Dashboard.stats(subject)
    health = Dashboard.health_data(subject)
    recent_policy_authorizations = Dashboard.recent_policy_authorizations(subject)
    recent_sessions = Dashboard.recent_sessions(subject)

    online_gateway_count = Presence.Gateways.Account.list(account_id) |> map_size()
    online_client_count = Presence.Clients.Account.list(account_id) |> map_size()

    online_site_ids = compute_online_site_ids(account_id)
    gateways_by_site = compute_gateways_by_site(account_id, subject)

    sites_without_gateways =
      Enum.filter(health.sites, fn site -> not MapSet.member?(online_site_ids, site.id) end)

    socket =
      socket
      |> assign(page_title: "Dashboard")
      |> assign(stats: stats)
      |> assign(online_gateway_count: online_gateway_count)
      |> assign(online_client_count: online_client_count)
      |> assign(sites_without_gateways: sites_without_gateways)
      |> assign(gateways_by_site: gateways_by_site)
      |> assign(all_sites: health.sites)
      |> assign(site_gateway_totals: health.site_gateway_totals)
      |> assign(site_resource_counts: health.site_resource_counts)
      |> assign(disabled_providers: health.disabled_providers)
      |> assign(recent_policy_authorizations: recent_policy_authorizations)
      |> assign(recent_sessions: recent_sessions)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_gateways:" <> _account_id},
        socket
      ) do
    account_id = socket.assigns.account.id
    subject = socket.assigns.subject

    online_gateway_count = Presence.Gateways.Account.list(account_id) |> map_size()
    online_site_ids = compute_online_site_ids(account_id)
    gateways_by_site = compute_gateways_by_site(account_id, subject)

    sites_without_gateways =
      Enum.filter(socket.assigns.all_sites, fn site ->
        not MapSet.member?(online_site_ids, site.id)
      end)

    health = Dashboard.health_data(subject)

    socket =
      socket
      |> assign(online_gateway_count: online_gateway_count)
      |> assign(sites_without_gateways: sites_without_gateways)
      |> assign(gateways_by_site: gateways_by_site)
      |> assign(disabled_providers: health.disabled_providers)

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presences:account_clients:" <> _account_id},
        socket
      ) do
    online_client_count = Presence.Clients.Account.list(socket.assigns.account.id) |> map_size()
    {:noreply, assign(socket, online_client_count: online_client_count)}
  end

  def handle_info({:policy_authorization_created, _account_id}, socket) do
    subject = socket.assigns.subject
    recent_policy_authorizations = Dashboard.recent_policy_authorizations(subject)
    {:noreply, assign(socket, recent_policy_authorizations: recent_policy_authorizations)}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-[1400px] w-full mx-auto px-4 py-4 md:px-6 md:py-6 space-y-6">
      <%!-- Page header --%>
      <div class="flex items-start justify-between">
        <div>
          <h1 class="text-xl font-semibold tracking-tight text-[var(--text-primary)]">Dashboard</h1>
          <p class="text-xs text-[var(--text-tertiary)] mt-0.5">
            Infrastructure &amp; access overview
          </p>
        </div>
        <%!-- Health warning summary badge --%>
        <div
          :if={health_issues?(assigns)}
          class="flex items-center gap-1.5 text-xs text-[var(--status-warn)]"
        >
          <.icon name="remix-error-warning-fill" class="w-4 h-4 shrink-0" />
          <span>
            {warning_count(assigns)} issue{if warning_count(assigns) != 1, do: "s"} detected
          </span>
        </div>
      </div>

      <%!-- Health warnings detail --%>
      <div
        :if={health_issues?(assigns)}
        class="flex items-start gap-2.5 px-4 py-3 border border-[var(--border)] rounded bg-[var(--surface-raised)] text-xs text-[var(--text-secondary)]"
      >
        <.icon
          name="remix-error-warning-fill"
          class="w-4 h-4 mt-0.5 shrink-0 text-[var(--status-warn)]"
        />
        <div class="space-y-1">
          <p :if={Billing.any_limit_exceeded?(@account)}>
            <span class="font-medium text-[var(--status-warn)]">Account limit exceeded</span>
            — some features may be restricted.
            <.link
              navigate={~p"/#{@account}/settings/account"}
              class="underline hover:text-[var(--text-primary)]"
            >
              View details
            </.link>
          </p>
          <p :for={site <- @sites_without_gateways}>
            <span class="font-medium text-[var(--status-warn)]">
              <.link
                navigate={~p"/#{@account}/sites"}
                class="underline hover:text-[var(--text-primary)]"
              >
                {site.name}
              </.link>
            </span>
            has no online gateways.
          </p>
          <p :for={provider <- @disabled_providers}>
            Auth provider
            <.link
              navigate={~p"/#{@account}/settings/authentication"}
              class="font-medium text-[var(--status-warn)] underline hover:text-[var(--text-primary)]"
            >
              {provider.name}
            </.link>
            is disabled.
          </p>
        </div>
      </div>

      <%!-- Summary bar --%>
      <div class="flex flex-wrap items-stretch gap-3 md:gap-5">
        <.link navigate={~p"/#{@account}/sites"} class="dash-chip dash-chip--blue">
          <div class="dash-chip__left">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
              <path d="M8 1a4.5 4.5 0 00-4.5 4.5c0 3 4.5 9.5 4.5 9.5s4.5-6.5 4.5-9.5A4.5 4.5 0 008 1z" />
              <circle cx="8" cy="5.5" r="1.5" />
            </svg>
          </div>
          <div class="dash-chip__right">
            <span class="dash-chip__label">Sites</span>
            <span class="dash-chip__num">{@stats.sites}</span>
          </div>
        </.link>

        <.link navigate={~p"/#{@account}/resources"} class="dash-chip dash-chip--teal">
          <div class="dash-chip__left">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
              <rect x="1.5" y="1.5" width="13" height="5" rx="1" />
              <rect x="1.5" y="9.5" width="13" height="5" rx="1" />
              <circle cx="4" cy="4" r="0.75" fill="currentColor" stroke="none" />
              <circle cx="4" cy="12" r="0.75" fill="currentColor" stroke="none" />
            </svg>
          </div>
          <div class="dash-chip__right">
            <span class="dash-chip__label">Resources</span>
            <span class="dash-chip__num">{@stats.resources}</span>
          </div>
        </.link>

        <.link navigate={~p"/#{@account}/policies"} class="dash-chip dash-chip--orange">
          <div class="dash-chip__left">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
              <path d="M8 1.5L2 4v4c0 3.31 2.69 6 6 6s6-2.69 6-6V4L8 1.5z" />
            </svg>
          </div>
          <div class="dash-chip__right">
            <span class="dash-chip__label">Active Policies</span>
            <span class="dash-chip__num">{@stats.policies}</span>
          </div>
        </.link>

        <.link navigate={~p"/#{@account}/groups"} class="dash-chip dash-chip--purple">
          <div class="dash-chip__left">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
              <circle cx="6" cy="5" r="2.5" /><path d="M1 13c0-2.76 2.24-5 5-5" />
              <circle cx="11" cy="6" r="2" /><path d="M10 13h4c0-2.21-1.79-4-4-4" />
            </svg>
          </div>
          <div class="dash-chip__right">
            <span class="dash-chip__label">Groups</span>
            <span class="dash-chip__num">{@stats.groups}</span>
          </div>
        </.link>

        <.link navigate={~p"/#{@account}/actors"} class="dash-chip dash-chip--slate">
          <div class="dash-chip__left">
            <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5">
              <circle cx="8" cy="5" r="3" /><path d="M2 14c0-3.31 2.69-6 6-6s6 2.69 6 6" />
            </svg>
          </div>
          <div class="dash-chip__right">
            <span class="dash-chip__label">Actors</span>
            <span class="dash-chip__num">{@stats.users + @stats.service_accounts}</span>
          </div>
        </.link>
      </div>

      <%!-- Site cards grid --%>
      <div class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        <div
          :if={Enum.empty?(@all_sites)}
          class="col-span-full px-4 py-10 text-sm text-center text-[var(--text-tertiary)] border border-[var(--border)] rounded bg-[var(--surface)]"
        >
          No sites configured.
        </div>
        <.link
          :for={site <- @all_sites}
          navigate={~p"/#{@account}/sites/#{site.id}"}
          class="rounded border border-[var(--border)] bg-[var(--surface)] overflow-hidden hover:shadow-sm transition-shadow"
        >
          <%!-- Card header --%>
          <div class={"dash-site-header dash-site-header--#{site_status(site.id, @gateways_by_site, @site_gateway_totals)}"}>
            <div class="dash-site-header__icon">
              <svg
                class="w-3.5 h-3.5"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path d="M8 1a4.5 4.5 0 00-4.5 4.5c0 3 4.5 9.5 4.5 9.5s4.5-6.5 4.5-9.5A4.5 4.5 0 008 1z" />
                <circle cx="8" cy="5.5" r="1.5" />
              </svg>
            </div>
            <h2 class="text-sm font-semibold text-[var(--text-primary)] flex-1 truncate">
              {site.name}
            </h2>
            <span class={"dash-site-badge dash-site-badge--#{site_status(site.id, @gateways_by_site, @site_gateway_totals)}"}>
              {site_status_label(site.id, @gateways_by_site, @site_gateway_totals)}
            </span>
          </div>
          <%!-- Stats row --%>
          <div class="grid grid-cols-2 divide-x divide-[var(--border)] border-b border-[var(--border)]">
            <div class="px-4 py-3 text-center">
              <p class="text-[10px] uppercase tracking-widest text-[var(--text-tertiary)] font-semibold mb-0.5">
                Gateways
              </p>
              <p class="text-lg font-bold text-[var(--text-primary)] leading-none">
                {length(Map.get(@gateways_by_site, site.id, []))}
                <span class="text-xs font-normal text-[var(--text-muted)]">
                  /{Map.get(@site_gateway_totals, site.id, 0)}
                </span>
              </p>
              <p class="text-[10px] text-[var(--text-muted)] mt-0.5">online</p>
            </div>
            <div class="px-4 py-3 text-center">
              <p class="text-[10px] uppercase tracking-widest text-[var(--text-tertiary)] font-semibold mb-0.5">
                Resources
              </p>
              <p class="text-lg font-bold text-[var(--text-primary)] leading-none">
                {Map.get(@site_resource_counts, site.id, 0)}
              </p>
              <p class="text-[10px] text-[var(--text-muted)] mt-0.5">assigned</p>
            </div>
          </div>
          <%!-- Gateway list --%>
          <div class="divide-y divide-[var(--border)]">
            <div
              :if={Map.get(@gateways_by_site, site.id, []) == []}
              class="px-4 py-3 text-[10px] text-[var(--text-muted)] text-center"
            >
              No gateways online
            </div>
            <div
              :for={gw <- Map.get(@gateways_by_site, site.id, [])}
              class="grid grid-cols-3 items-center px-4 py-2.5"
            >
              <span class="text-xs font-medium text-[var(--text-primary)] truncate">
                {gw.name || gw.id}
              </span>
              <span class="flex items-center justify-center">
                <span class={"dash-gw-version #{if gw.outdated?, do: "dash-gw-version--outdated", else: "dash-gw-version--current"}"}>
                  <%= if gw.outdated? do %>
                    <svg
                      class="w-2.5 h-2.5 shrink-0"
                      viewBox="0 0 16 16"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.75"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M8 2L1.5 13h13L8 2z" /><path d="M8 7v3M8 11.5v.5" />
                    </svg>
                  <% else %>
                    <svg
                      class="w-2.5 h-2.5 shrink-0"
                      viewBox="0 0 16 16"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="1.75"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M3 8l3.5 3.5L13 5" />
                    </svg>
                  <% end %>
                  {gw.version || "—"}
                </span>
              </span>
              <span class="flex justify-end">
                <span class="dash-gw-pill dash-gw-pill--online">online</span>
              </span>
            </div>
          </div>
        </.link>
      </div>

      <%!-- Bottom row: recent sessions + policy auth feed --%>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <%!-- Recent sessions --%>
        <div class="rounded border border-[var(--border)] bg-[var(--surface)] overflow-hidden">
          <div class="dash-panel-header dash-panel-header--blue">
            <div class="dash-panel-header__icon">
              <svg
                class="w-3.5 h-3.5"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <circle cx="8" cy="5" r="3" /><path d="M2 14c0-3.31 2.69-6 6-6s6 2.69 6 6" />
              </svg>
            </div>
            <div>
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Recent Sessions</h2>
              <p class="text-[10px] text-[var(--text-tertiary)] mt-0.5">Latest client sign-ins</p>
            </div>
          </div>
          <div class="divide-y divide-[var(--border)]">
            <div
              :if={Enum.empty?(@recent_sessions)}
              class="px-4 py-10 text-sm text-center text-[var(--text-tertiary)]"
            >
              No client sessions yet.
            </div>
            <div
              :for={session <- @recent_sessions}
              class="flex items-center gap-3 px-4 py-2.5 hover:bg-[var(--surface-raised)] transition-colors"
            >
              <span class={"flex-shrink-0 flex items-center justify-center w-7 h-7 rounded-full text-xs font-semibold #{avatar_class(session.client.actor.name)}"}>
                {String.first(session.client.actor.name || "?")}
              </span>
              <div class="flex-1 min-w-0">
                <p class="text-xs font-medium text-[var(--text-primary)] truncate">
                  {session.client.actor.name}
                </p>
                <p :if={session.version} class="text-[10px] text-[var(--text-tertiary)] truncate">
                  {session.version}
                </p>
              </div>
              <span class="shrink-0 text-[10px] text-[var(--text-muted)] w-16 text-right">
                <.relative_datetime datetime={session.inserted_at} />
              </span>
            </div>
          </div>
        </div>

        <%!-- Policy auth feed --%>
        <div class="rounded border border-[var(--border)] bg-[var(--surface)] overflow-hidden">
          <div class="dash-panel-header dash-panel-header--purple">
            <div class="dash-panel-header__icon">
              <svg
                class="w-3.5 h-3.5"
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
              >
                <path d="M8 1.5L2 4v4c0 3.31 2.69 6 6 6s6-2.69 6-6V4L8 1.5z" />
                <path d="M5.5 8l2 2 3-3" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </div>
            <div class="flex-1">
              <h2 class="text-sm font-semibold text-[var(--text-primary)]">Policy Authorizations</h2>
              <p class="text-[10px] text-[var(--text-tertiary)] mt-0.5">Live allow / deny feed</p>
            </div>
            <span class="relative flex h-2 w-2 shrink-0">
              <span class="absolute inline-flex h-full w-full rounded-full bg-[var(--status-active)] opacity-60 animate-ping">
              </span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-[var(--status-active)]">
              </span>
            </span>
          </div>
          <div class="divide-y divide-[var(--border)]">
            <div
              :if={Enum.empty?(@recent_policy_authorizations)}
              class="px-4 py-10 text-sm text-center text-[var(--text-tertiary)]"
            >
              No authorizations yet.
            </div>
            <div
              :for={auth <- @recent_policy_authorizations}
              class="flex items-center gap-3 px-4 py-2.5 hover:bg-[var(--surface-raised)] transition-colors"
            >
              <span class="shrink-0 text-[10px] font-semibold px-1.5 py-0.5 rounded w-12 text-center bg-[var(--status-active-bg)] text-[var(--status-active)]">
                allowed
              </span>
              <div class="flex-1 min-w-0">
                <p class="text-xs text-[var(--text-primary)] truncate">
                  <.link
                    navigate={~p"/#{@account}/resources/#{auth.resource_id}"}
                    class="hover:text-[var(--brand)] transition-colors"
                  >
                    {auth.resource.name}
                  </.link>
                </p>
                <p class="text-[10px] text-[var(--text-tertiary)] truncate">
                  {auth.client.actor.name}
                </p>
              </div>
              <span class="shrink-0 text-[10px] text-[var(--text-muted)] w-16 text-right">
                <.relative_datetime datetime={auth.inserted_at} />
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp health_issues?(assigns) do
    Billing.any_limit_exceeded?(assigns.account) or
      assigns.sites_without_gateways != [] or
      assigns.disabled_providers != []
  end

  defp warning_count(assigns) do
    billing = if Billing.any_limit_exceeded?(assigns.account), do: 1, else: 0
    billing + length(assigns.sites_without_gateways) + length(assigns.disabled_providers)
  end

  defp site_status(site_id, gateways_by_site, site_gateway_totals) do
    online = length(Map.get(gateways_by_site, site_id, []))
    total = Map.get(site_gateway_totals, site_id, 0)

    cond do
      total == 0 or online == 0 -> "offline"
      online < total -> "degraded"
      true -> "healthy"
    end
  end

  defp site_status_label(site_id, gateways_by_site, site_gateway_totals) do
    case site_status(site_id, gateways_by_site, site_gateway_totals) do
      "healthy" -> "Healthy"
      "degraded" -> "Degraded"
      "offline" -> "Offline"
    end
  end

  defp avatar_class(name) do
    case name |> String.first() |> String.downcase() do
      c when c in ~w(a b c d e) -> "dash-avatar--blue"
      c when c in ~w(f g h i j) -> "dash-avatar--purple"
      c when c in ~w(k l m n o) -> "dash-avatar--green"
      c when c in ~w(p q r s t) -> "dash-avatar--amber"
      _ -> "dash-avatar--rose"
    end
  end

  defp compute_online_site_ids(account_id) do
    account_id
    |> Presence.Gateways.Account.list()
    |> Enum.map(fn {_gateway_id, %{metas: [meta | _]}} -> Map.get(meta, :site_id) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp compute_gateways_by_site(account_id, subject) do
    presence = Presence.Gateways.Account.list(account_id)
    latest_version = Portal.ComponentVersions.gateway_version()

    gateway_ids = Enum.map(presence, fn {gateway_id, _} -> gateway_id end)
    names = Dashboard.gateway_names(subject, gateway_ids)

    presence
    |> Enum.flat_map(fn {gateway_id, %{metas: [meta | _]}} ->
      case Map.get(meta, :site_id) do
        nil ->
          []

        site_id ->
          version = Map.get(meta, :version)

          outdated? =
            if version do
              case Version.compare(version, latest_version) do
                :lt -> true
                _ -> false
              end
            else
              false
            end

          [
            {site_id,
             %{
               id: gateway_id,
               name: Map.get(names, gateway_id),
               version: version,
               outdated?: outdated?
             }}
          ]
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {site_id, gateways} -> {site_id, Enum.take(gateways, 3)} end)
  end
end
