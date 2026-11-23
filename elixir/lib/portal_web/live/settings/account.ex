defmodule PortalWeb.Settings.Account do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Account
  alias Portal.Accounts.Deletion
  alias Portal.Billing
  alias Portal.Mailer.InternalEmail
  alias PortalWeb.Actors
  alias PortalWeb.Devices
  alias PortalWeb.Settings
  alias __MODULE__.Database
  require Logger

  @slug_changes_per_window 3
  @usage_page_size 50
  @usage_items ~w[seats adhoc_service_accounts users service_accounts admins sites]
  @slug_change_window_days 30

  # First path segments the router already uses.
  # Top-level routes, static path prefixes, region names, and words that
  # would make a sign-in URL or email look official.
  @reserved_slugs ~w(
    auth browser dev error find_account getting_started oauth sign_in sign_up try verification verify_sign_up
    assets downloads fonts images
    us eu
    firezone admin administrator account accounts api app billing docs email help login logout mail mcp
    official root security settings signin signup staff status support system www
  )

  def mount(_params, session, socket) do
    account = socket.assigns.account
    slug_history = Database.list_account_slugs(socket.assigns.subject)

    socket =
      assign(socket,
        marketing_attribution: get_in(PortalWeb.WebsiteAttribution.fetch(session) || %{}, ["marketing"]),
        page_title: "Account",
        billing_provisioned: Billing.account_provisioned?(account),
        billing_plan_type: Billing.plan_type(account),
        data_residency_region: Page.data_residency_region(),
        region_transfer_enabled: region_transfer_enabled?(Page.data_residency_region()),
        region_transfer_open: false,
        error: nil,
        slug_confirmation: "",
        confirm_delete_account: false,
        deletion_feedback_form: nil,
        edit_account_open: false,
        slug_history: slug_history,
        account_form: to_form(account_changeset(account, %{}, slug_history)),
        usage: if(connected?(socket), do: load_usage(account, socket.assigns.subject)),
        usage_panel: nil
      )

    {:ok, socket}
  end

  def handle_params(%{"item" => item}, _uri, %{assigns: %{live_action: :usage}} = socket)
      when item in @usage_items do
    {:noreply, assign(socket, usage_panel: load_usage_panel(socket, item, 1, ""))}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :usage}}) do
    raise PortalWeb.LiveErrors.NotFoundError
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, usage_panel: nil)}
  end

  # The static render shows a skeleton instead, so usage is only counted once,
  # by the connected mount.
  defp load_usage(account, subject) do
    monthly_active_usage = Billing.monthly_active_usage(account)

    %{
      admins_count: Database.count_account_admin_users_for_account(subject),
      service_accounts_count: Database.count_service_accounts_for_account(subject),
      users_count: Database.count_users_for_account(subject),
      active_users_count: monthly_active_usage.seats,
      adhoc_service_accounts_count: monthly_active_usage.adhoc_service_accounts,
      sites_count: Database.count_groups_for_account(subject)
    }
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <Navigation.settings_nav account={@account} current_path={@current_path}>
        <:actions>
          <Form.button id="edit-account-button" phx-click="open_edit_account" size="sm" icon="ri-pencil-line">
            Edit
          </Form.button>
        </:actions>
      </Navigation.settings_nav>

      <div class="flex-1 overflow-y-auto px-6 pb-10">
        <div class="max-w-5xl space-y-8">
          <section id="plan">
            <.eyebrow icon="ri-vip-crown-line">Plan</.eyebrow>
            <Settings.Components.tiles>
              <Settings.Components.tile id="plan-tile" label="Plan" icon="ri-price-tag-3-line">
                <p class="text-lg font-bold text-fg">{plan_name(@account)}</p>
                <p :if={not @billing_provisioned} class="mt-1 text-xs text-muted">
                  This account has not had billing provisioned.
                </p>
                <div
                  :if={@billing_provisioned and @billing_plan_type == :enterprise}
                  class="mt-2 flex items-start gap-2 text-xs text-muted"
                >
                  <Core.icon name="ri-customer-service-2-line" class="w-4 h-4 shrink-0 text-fg" />
                  <span>
                    <span class="block font-semibold text-fg">Enterprise plan</span>
                    Contact your account manager for plan changes.
                  </span>
                </div>
                <div :if={@billing_provisioned and @billing_plan_type != :enterprise} class="mt-3">
                  <Form.button
                    phx-click="redirect_to_billing_portal"
                    size="xs"
                    icon="ri-bank-card-line"
                  >
                    Manage plan
                  </Form.button>
                </div>
              </Settings.Components.tile>

              <Settings.Components.tile
                :if={@billing_provisioned}
                id="billing-email-tile"
                label="Billing email"
                icon="ri-mail-line"
              >
                <p class="text-sm text-fg break-all">{@account.metadata.stripe.billing_email}</p>
              </Settings.Components.tile>

              <Settings.Components.tile
                :if={@billing_provisioned}
                id="support-tile"
                label="Support type"
                icon="ri-customer-service-line"
              >
                <p class="text-sm text-fg">
                  {billing_support_label(@account.metadata.stripe.support_type)}
                </p>
              </Settings.Components.tile>

              <Settings.Components.tile
                :if={@billing_provisioned and @account.metadata.stripe.add_ons != []}
                id="add-ons-tile"
                label="Add-ons"
                icon="ri-add-box-line"
              >
                <ul class="space-y-1">
                  <li
                    :for={add_on <- @account.metadata.stripe.add_ons}
                    class="flex justify-between gap-3 text-sm text-fg"
                  >
                    <span>{add_on.name}</span>
                    <span class="tabular-nums text-muted">× {add_on.quantity}</span>
                  </li>
                </ul>
              </Settings.Components.tile>
            </Settings.Components.tiles>
          </section>

          <section id="usage-section">
            <.eyebrow icon="ri-bar-chart-line">Usage</.eyebrow>
            <Settings.Components.skeleton :if={is_nil(@usage)} id="usage-skeleton" rows={3} />
            <Settings.Components.tiles :if={@usage} id="usage">
              <.usage_tile
                :if={not is_nil(effective_limit(@account, :monthly_active_users_count))}
                label="Seats"
                icon="ri-user-star-line"
                patch={~p"/#{@account}/settings/account/usage/seats"}
                description="Users and service accounts with a device active in the last month"
                used={@usage.active_users_count}
                limit={effective_limit(@account, :monthly_active_users_count)}
              />
              <.usage_tile
                :if={(effective_limit(@account, :adhoc_service_accounts_count) || 0) > 0}
                label="Ad hoc service accounts"
                icon="ri-robot-2-line"
                patch={~p"/#{@account}/settings/account/usage/adhoc_service_accounts"}
                description="Active service accounts that do not take a seat"
                used={@usage.adhoc_service_accounts_count}
                limit={effective_limit(@account, :adhoc_service_accounts_count)}
              />
              <.usage_tile
                label="Users"
                icon="ri-user-line"
                patch={~p"/#{@account}/settings/account/usage/users"}
                used={@usage.users_count}
                limit={effective_limit(@account, :users_count)}
              />
              <.usage_tile
                label="Service accounts"
                icon="ri-robot-line"
                patch={~p"/#{@account}/settings/account/usage/service_accounts"}
                used={@usage.service_accounts_count}
                limit={effective_limit(@account, :service_accounts_count)}
              />
              <.usage_tile
                label="Admins"
                icon="ri-shield-user-line"
                patch={~p"/#{@account}/settings/account/usage/admins"}
                used={@usage.admins_count}
                limit={effective_limit(@account, :account_admin_users_count)}
              />
              <.usage_tile
                label="Sites"
                icon="ri-building-line"
                patch={~p"/#{@account}/settings/account/usage/sites"}
                used={@usage.sites_count}
                limit={effective_limit(@account, :sites_count)}
              />
            </Settings.Components.tiles>
          </section>

          <section id="plan-features">
            <.eyebrow icon="ri-function-line">Plan features</.eyebrow>
            <Settings.Components.tiles>
              <.feature_tile
                label="Identity provider sync"
                icon="ri-loop-left-line"
                enabled={feature_enabled?(@account, :idp_sync)}
              />
              <.feature_tile
                label="Internet resource"
                icon="ri-earth-line"
                enabled={feature_enabled?(@account, :internet_resource)}
              />
              <.feature_tile
                label="Policy conditions"
                icon="ri-filter-3-line"
                enabled={feature_enabled?(@account, :policy_conditions)}
              />
              <.feature_tile
                label="Log sinks"
                icon="ri-upload-cloud-2-line"
                enabled={feature_enabled?(@account, :log_sinks)}
              />
              <.feature_tile
                label="Device posture"
                icon="ri-shield-star-line"
                enabled={feature_enabled?(@account, :device_posture)}
              />
              <.feature_tile
                label="Account slug changes"
                icon="ri-links-line"
                enabled={feature_enabled?(@account, :slug_changes)}
              />
            </Settings.Components.tiles>
          </section>

          <section :if={@data_residency_region != :on_prem} id="data-residency">
            <.eyebrow icon="ri-map-pin-line">Data residency</.eyebrow>
            <Settings.Components.tiles cols="2">
              <Settings.Components.tile label="Cloud region" icon="ri-cloud-line">
                <div class="flex items-center gap-2">
                  <Page.residency_flag region={@data_residency_region} />
                  <span class="text-sm text-fg">
                    Cloud region: <strong>{Page.data_residency_name(@data_residency_region)}</strong>
                  </span>
                </div>
                <p class="mt-2 text-xs text-muted">
                  <a
                    href="https://www.firezone.dev/kb/architecture/regional-availability"
                    target="_blank"
                    rel="noopener"
                    class={Core.link_style()}
                  >
                    Learn more about Firezone Cloud regions.
                  </a>
                </p>
                <div :if={@region_transfer_enabled} class="mt-3">
                  <Form.button
                    id="request-region-transfer"
                    phx-click="open_region_transfer"
                    size="xs"
                    icon="ri-arrow-left-right-line"
                  >
                    Request transfer to the {Page.data_residency_name(
                      Page.other_region(@data_residency_region)
                    )} region
                  </Form.button>
                </div>
              </Settings.Components.tile>
              <Settings.Components.tile label="Data stored in" icon="ri-database-2-line">
                <ul class="space-y-1 text-sm text-fg">
                  <li
                    :for={{city, country} <- Page.data_residency_locations(@data_residency_region)}
                    class="flex items-center gap-1.5"
                  >
                    <Core.icon name="ri-map-pin-line" class="w-3.5 h-3.5 text-muted" />
                    {city}, {country}
                  </li>
                </ul>
              </Settings.Components.tile>
            </Settings.Components.tiles>
          </section>

          <section
            :if={not Account.locked?(@account) and Account.pending_deletion?(@account)}
            id="pending-deletion"
          >
            <.eyebrow icon="ri-time-line">Actions</.eyebrow>
            <div class="border border-rule px-5 py-4 max-w-2xl">
              <p class="text-sm text-fg">
                This account is scheduled for deletion on <strong>{Calendar.strftime(@account.scheduled_deletion_at, "%B %-d, %Y")}</strong>.
              </p>
              <p
                :if={Portal.Billing.paid_plan?(@account)}
                class="mt-2 flex items-start gap-2 text-xs text-attn"
              >
                <Core.icon name="ri-error-warning-line" class="w-4 h-4 shrink-0" />
                You are on a paid plan. Any remaining time left on your subscription will be lost when the account is deleted.
              </p>
              <div class="mt-3">
                <Form.button
                  type="button"
                  phx-click="cancel_account_deletion"
                  size="xs"
                  icon="ri-arrow-go-back-line"
                >
                  Cancel deletion
                </Form.button>
              </div>
              <Core.flash :if={@error} kind={:error} class="mt-2">
                {@error}
              </Core.flash>
            </div>
          </section>

          <section
            :if={Account.active?(@account) and not Account.locked?(@account)}
            id="danger-zone"
          >
            <.eyebrow icon="ri-alarm-warning-line">Danger zone</.eyebrow>
            <div class="border border-rule px-5 py-4 max-w-2xl">
              <div :if={not @confirm_delete_account} class="flex items-center gap-4">
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-fg">Delete this account</p>
                  <p class="text-xs text-muted">
                    Disables the account at once and deletes all data after 7 days.
                  </p>
                </div>
                <Form.button
                  type="button"
                  phx-click="confirm_delete_account"
                  style="danger"
                  size="xs"
                  icon="ri-delete-bin-line"
                  class="ml-auto shrink-0"
                >
                  Delete account
                </Form.button>
              </div>

              <div :if={@confirm_delete_account}>
                <p class="text-sm font-semibold text-attn">Delete this account?</p>
                <p class="mt-1 text-xs text-muted">
                  This will <strong class="text-fg">immediately disable</strong>
                  your account and <strong class="text-fg">permanently delete</strong>
                  all data after 7 days.
                </p>
                <p class="mt-3 mb-1.5 text-xs text-muted">
                  Type <strong class="font-mono text-fg">{@account.slug}</strong> to confirm:
                </p>
                <form
                  id="delete-account-form"
                  phx-change="update_slug_confirmation"
                  phx-submit="delete_account"
                >
                  <input
                    type="text"
                    name="slug_confirmation"
                    value={@slug_confirmation}
                    placeholder={@account.slug}
                    autocomplete="off"
                    class="w-full max-w-xs mb-3 border border-rule bg-bg px-2 py-1.5 text-sm text-fg placeholder:text-faint focus:outline-none focus:border-attn"
                  />
                  <div class="flex items-center gap-2">
                    <Form.button type="button" phx-click="cancel_delete_account" size="xs">
                      Cancel
                    </Form.button>
                    <Form.button
                      type="submit"
                      disabled={@slug_confirmation != @account.slug}
                      style="danger"
                      size="xs"
                    >
                      Delete
                    </Form.button>
                  </div>
                </form>
                <Core.flash :if={@error} kind={:error} class="mt-2">
                  {@error}
                </Core.flash>
              </div>
            </div>
          </section>
        </div>
      </div>

      <Form.modal
        :if={@deletion_feedback_form}
        id="deletion-feedback-modal"
        on_close="skip_deletion_feedback"
        on_cancel="skip_deletion_feedback"
      >
        <:title>Sorry Firezone didn't work out</:title>
        <:body>
          <p class="mb-4">Anything you'd like to share about your experience?</p>
          <.form
            id="deletion-feedback-form"
            for={@deletion_feedback_form}
            phx-submit="submit_deletion_feedback"
          >
            <Form.input
              field={@deletion_feedback_form[:feedback]}
              type="textarea"
              placeholder="Your feedback (optional)"
              maxlength={Deletion.feedback_max_length()}
            />
          </.form>
        </:body>
        <:cancel_button>Skip</:cancel_button>
        <:confirm_button form="deletion-feedback-form" type="submit">
          Send feedback
        </:confirm_button>
      </Form.modal>

      <Form.modal
        :if={@region_transfer_open}
        id="region-transfer-modal"
        on_close="close_region_transfer"
        on_cancel="close_region_transfer"
        on_confirm="request_region_transfer"
      >
        <:title>
          Transfer your account to the {Page.data_residency_name(Page.other_region(@data_residency_region))} region?
        </:title>
        <:body>
          <div class="space-y-3 text-sm text-fg">
            <p>
              This opens a support request to move your account, and all of its data, to the
              {Page.data_residency_name(Page.other_region(@data_residency_region))} region.
              Firezone support will contact <strong>{@subject.actor.email}</strong>
              to schedule the transfer.
            </p>
            <p>
              The transfer needs a maintenance window of up to 8 hours. During that window
              your account is disabled: nobody can sign in, Clients cannot connect, and
              Gateways are offline.
            </p>
            <p>
              After the transfer, every session, Gateway token, service account token, and
              API token is invalid. Users sign in again, and a sign-in on the old portal
              redirects to the new one.
            </p>
            <p>
              Clients at these versions or later switch to the new region on their own, so
              they need no configuration change: macOS and iOS 1.5.24, Android 1.5.18,
              Windows and Linux 1.5.20. Older Clients, headless Clients, and Gateways need
              the new URLs: set the auth URL to
              <code>{Page.portal_url(Page.other_region(@data_residency_region))}</code>
              and the API URL to
              <code>{Page.api_url(Page.other_region(@data_residency_region))}</code>.
              Each Gateway also needs a new token, and headless Clients need new service
              account tokens. Recreate every API token and reconnect your MCP clients.
            </p>
            <p>
              Before the transfer, add
              <code>{Page.portal_url(Page.other_region(@data_residency_region))}/auth/oidc/callback</code>
              as an additional redirect URI in your identity provider for every Okta and
              custom OIDC authentication provider, so users can sign in after the move.
            </p>
            <p>
              Logs are not moved. They are deleted from the old region when the transfer
              completes, and that region's database backups expire 30 days later.
            </p>
            <p :if={Portal.Billing.paid_plan?(@account)}>
              Your billing moves too. We recreate your subscription under a new billing
              customer in the {Page.data_residency_name(Page.other_region(@data_residency_region))} region,
              apply any remaining credit at the exchange rate on the day of the transfer, and
              bill in {billing_currency(Page.other_region(@data_residency_region))} from then on.
            </p>
          </div>
        </:body>
        <:cancel_button>Cancel</:cancel_button>
        <:confirm_button>Send request</:confirm_button>
      </Form.modal>

      <.usage_panel account={@account} panel={@usage_panel} />

      <.edit_account_panel
        open={@edit_account_open}
        form={@account_form}
        account={@account}
        slug_changes_left={slug_changes_left(@slug_history)}
      />
    </div>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp eyebrow(assigns) do
    ~H"""
    <h2 class="flex items-center gap-1.5 mb-3 text-[11px] font-semibold tracking-[.12em] uppercase text-muted">
      <Core.icon name={@icon} class="w-3.5 h-3.5" />
      {render_slot(@inner_block)}
    </h2>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :enabled, :boolean, required: true

  defp feature_tile(assigns) do
    ~H"""
    <div class="flex items-center gap-2.5 px-5 py-3 border-r border-b border-rule">
      <Core.icon name={@icon} class={["w-4 h-4 shrink-0", feature_icon_class(@enabled)]} />
      <span class={["text-sm", feature_label_class(@enabled)]}>{@label}</span>
      <Core.icon
        :if={@enabled}
        name="ri-check-line"
        title="Included"
        class="ml-auto w-4 h-4 shrink-0 text-fg"
      />
      <span :if={not @enabled} class="ml-auto text-xs text-faint">Not included</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :patch, :string, required: true
  attr :used, :integer, required: true
  attr :limit, :integer, default: nil
  attr :description, :string, default: nil

  defp usage_tile(assigns) do
    over? =
      is_integer(assigns.used) and is_integer(assigns.limit) and assigns.used > assigns.limit

    assigns = assign(assigns, :over?, over?)

    ~H"""
    <.link
      patch={@patch}
      class={[
        "flex flex-col min-w-0 px-5 py-4 border-r border-b border-rule transition-colors",
        @over? && "bg-attn-wash hover:bg-attn-wash",
        not @over? && "hover:bg-hover"
      ]}
    >
      <span class="flex items-center gap-1.5 mb-2">
        <Core.icon
          name={@icon}
          class={["w-3.5 h-3.5 shrink-0", (@over? && "text-attn") || "text-muted"]}
        />
        <span class={[
          "text-[11px] font-semibold tracking-[.12em] uppercase",
          (@over? && "text-attn") || "text-muted"
        ]}>
          {@label}
        </span>
        <Core.icon name="ri-arrow-right-s-line" class="ml-auto w-4 h-4 text-faint" />
      </span>
      <span class="flex items-baseline gap-1.5">
        <span class={["text-2xl font-bold tabular-nums", (@over? && "text-attn") || "text-fg"]}>
          {@used}
        </span>
        <span :if={@limit} class="text-sm tabular-nums text-muted">/ {@limit}</span>
        <span :if={is_nil(@limit)} class="text-sm text-muted">used · Unlimited</span>
      </span>
      <span :if={@limit} class="sr-only">{@used} / {@limit}</span>
      <span class="mt-2 block h-1 bg-hover overflow-hidden">
        <span
          :if={@limit}
          id={"progress-#{@label |> String.downcase() |> String.replace(" ", "-")}"}
          phx-hook="ProgressBar"
          data-pct={bar_pct(@used, @limit)}
          class={["block h-full transition-all", (@over? && "bg-attn") || "bg-fg"]}
        >
        </span>
      </span>
      <span :if={@description} class="mt-2 text-xs text-muted">{@description}</span>
    </.link>
    """
  end

  defp bar_pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    min(div(used * 100, limit), 100)
  end

  defp bar_pct(_, _), do: 0

  attr :account, :any, required: true
  attr :panel, :map, default: nil

  defp usage_panel(assigns) do
    ~H"""
    <Page.detail_modal id="usage-panel" open={not is_nil(@panel)} on_close="close_usage_panel">
      <Form.panel_header :if={@panel} title={@panel.title} close_event="close_usage_panel">
        <:leading><Core.icon name="ri-bar-chart-line" class="w-4 h-4 text-muted" /></:leading>
      </Form.panel_header>
      <div :if={@panel} class="shrink-0 flex items-center gap-4 px-6 py-3 border-b border-hair">
        <p class="flex-1 min-w-0 text-xs text-muted">{@panel.description}</p>
        <form id="usage-filter-form" phx-change="filter_usage" phx-submit="filter_usage">
          <label class="flex items-center gap-1.5 w-56 px-2 py-1 border border-rule bg-bg focus-within:border-fg">
            <Core.icon name="ri-search-line" class="w-3.5 h-3.5 shrink-0 text-muted" />
            <input
              type="text"
              value={@panel.filter}
              placeholder={
                if @panel.kind == :sites, do: "Filter by name...", else: "Filter by name or email..."
              }
              phx-debounce="300"
              name="filter"
              autocomplete="off"
              data-1p-ignore
              class="flex-1 min-w-0 p-0 text-xs bg-transparent border-0 text-fg placeholder:text-faint outline-none focus:ring-0"
            />
          </label>
        </form>
      </div>

      <div :if={@panel} class="flex-1 min-h-0 overflow-y-auto">
        <Settings.Components.skeleton
          :if={is_nil(@panel.rows)}
          id="usage-panel-skeleton"
          rows={5}
        />
        <p
          :if={@panel.rows == []}
          id="usage-panel-empty"
          class="px-6 py-10 text-center text-sm text-muted"
        >
          {if @panel.filter == "", do: "Nothing to show.", else: "Nothing matches your filter."}
        </p>
        <table
          :if={@panel.rows not in [nil, []] and @panel.kind == :actors}
          class="w-full text-sm table-fixed"
        >
          <thead class="sticky top-0 bg-bg z-10">
            <tr class="border-b border-rule">
              <th class={[Settings.Components.th_class(), "w-2/5"]}>Name</th>
              <th class={[Settings.Components.th_class(), "w-2/5"]}>Device</th>
              <th class={Settings.Components.th_class()}>Last connected</th>
            </tr>
          </thead>
          <tbody id="usage-panel-rows">
            <tr
              :for={row <- @panel.rows}
              id={"usage-actor-#{row.actor.id}"}
              phx-click={JS.navigate(~p"/#{@account}/actors/#{row.actor}")}
              class="border-b border-hair hover:bg-hover cursor-pointer"
            >
              <td class="px-6 py-2">
                <.link
                  navigate={~p"/#{@account}/actors/#{row.actor}"}
                  class="flex items-center gap-2.5 min-w-0"
                >
                  <Actors.Components.actor_avatar account={@account} actor={row.actor} />
                  <span class="text-sm font-medium text-fg truncate">{row.actor.name}</span>
                </.link>
              </td>
              <td class="px-6 py-2">
                <Core.badge
                  :if={row.device}
                  class="max-w-full"
                  title={Devices.Components.os_name_and_version(row.device.last_seen_user_agent)}
                >
                  <Core.icon
                    name={Devices.Components.os_icon_name(row.device.last_seen_user_agent)}
                    class="w-3.5 h-3.5 shrink-0"
                  />
                  <span class="truncate">{row.device.name}</span>
                </Core.badge>
                <span :if={is_nil(row.device)} class="text-muted">None</span>
              </td>
              <td class="px-6 py-2 text-muted">
                <Core.relative_datetime datetime={row.actor.last_seen_at} popover={false} />
              </td>
            </tr>
          </tbody>
        </table>
        <table
          :if={@panel.rows not in [nil, []] and @panel.kind == :sites}
          class="w-full text-sm table-fixed"
        >
          <thead class="sticky top-0 bg-bg z-10">
            <tr class="border-b border-rule">
              <th class={[Settings.Components.th_class(), "w-4/5"]}>Name</th>
              <th class={Settings.Components.th_class()}>Gateways</th>
            </tr>
          </thead>
          <tbody id="usage-panel-rows">
            <tr
              :for={row <- @panel.rows}
              id={"usage-site-#{row.site.id}"}
              phx-click={JS.navigate(~p"/#{@account}/sites/#{row.site}")}
              class="border-b border-hair hover:bg-hover cursor-pointer"
            >
              <td class="px-6 py-2.5">
                <.link
                  navigate={~p"/#{@account}/sites/#{row.site}"}
                  class="flex items-center gap-2.5 min-w-0"
                >
                  <Core.icon name="ri-building-line" class="w-4 h-4 text-muted shrink-0" />
                  <span class="text-sm font-medium text-fg truncate">{row.site.name}</span>
                </.link>
              </td>
              <td class="px-6 py-2.5 text-fg tabular-nums">{row.gateways_count}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div
        :if={@panel && @panel.pages > 1}
        class="shrink-0 flex items-center justify-between px-6 py-2.5 border-t border-hair"
      >
        <span class="text-xs text-muted">
          Page {@panel.page} of {@panel.pages}
          <span class="text-faint">({@panel.total} total)</span>
        </span>
        <div class="flex items-center gap-1">
          <Form.icon_button
            style="outline"
            icon="ri-arrow-left-s-line"
            title="Previous page"
            phx-click="prev_usage_page"
            disabled={@panel.page <= 1}
          />
          <Form.icon_button
            style="outline"
            icon="ri-arrow-right-s-line"
            title="Next page"
            phx-click="next_usage_page"
            disabled={@panel.page >= @panel.pages}
          />
        </div>
      </div>
    </Page.detail_modal>
    """
  end

  attr :open, :boolean, required: true
  attr :form, :any, required: true
  attr :account, :any, required: true
  attr :slug_changes_left, :integer, required: true

  defp edit_account_panel(assigns) do
    assigns =
      assign(assigns,
        slug_changes_per_window: @slug_changes_per_window,
        slug_change_window_days: @slug_change_window_days
      )

    ~H"""
    <Page.detail_modal
      id="edit-account-panel"
      open={@open}
      on_close="close_edit_account"
      size="md"
    >
      <Form.panel_header title="Edit account" variant="plain" close_event="close_edit_account">
        <:leading><Core.icon name="ri-building-line" class="w-4 h-4 text-muted" /></:leading>
      </Form.panel_header>

      <.form
        id="account-form"
        for={@form}
        phx-change="change_account"
        phx-submit="submit_account"
        as={:account}
        class="flex flex-col flex-1 min-h-0"
      >
        <Settings.Components.modal_body class="space-y-5">
          <Form.input field={@form[:name]} label="Account name" phx-debounce="300" />
          <div :if={not Account.slug_changes_enabled?(@account)}>
            <Form.input field={@form[:slug]} type="readonly" label="Account slug" />
            <p id="slug-help" class="mt-2 text-xs text-muted">
              The slug is the first part of your portal URL and what users type to sign in.
              Slug changes are available on the Team plan and higher.
            </p>
          </div>
          <div :if={Account.slug_changes_enabled?(@account)}>
            <Form.input
              field={@form[:slug]}
              label="Account slug"
              phx-debounce="300"
              autocomplete="off"
              spellcheck="false"
            />
            <div id="slug-help" class="mt-2 space-y-1.5 text-xs text-muted">
              <p>
                The slug is the first part of your portal URL and what users type to sign in.
                Lowercase letters, numbers, and underscores only.
              </p>
              <p>
                Old slugs keep working: links that use them redirect to the new slug,
                and no other account can claim them. Your account ID
                <span class="font-mono text-fg">{@account.id}</span>
                always works in place of the slug.
              </p>
              <p>
                You can pick up to {@slug_changes_per_window} new slugs every {@slug_change_window_days} days.
                Switching back to a slug you used before does not count.
                <span :if={@slug_changes_left > 0} class="text-fg">
                  {@slug_changes_left} left.
                </span>
                <span :if={@slug_changes_left == 0} class="text-attn">
                  None left right now.
                </span>
              </p>
            </div>
          </div>
        </Settings.Components.modal_body>

        <Form.panel_footer>
          <Form.panel_footer_button type="button" phx-click="close_edit_account">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button type="submit" style="primary" disabled={not @form.source.valid?}>
            Save
          </Form.panel_footer_button>
        </Form.panel_footer>
      </.form>
    </Page.detail_modal>
    """
  end

  defp feature_icon_class(true), do: "text-fg"
  defp feature_icon_class(false), do: "text-faint"

  defp feature_label_class(true), do: "text-fg"
  defp feature_label_class(false), do: "text-muted"

  defp feature_enabled?(account, feature) do
    features = account.features || %Portal.Accounts.Features{}
    Map.get(features, feature) == true
  end

  defp plan_name(%{metadata: %{stripe: %{product_name: name}}})
       when is_binary(name) and name != "",
       do: name

  defp plan_name(_), do: "Starter"

  @starter_limits %{
    users_count: 6,
    monthly_active_users_count: nil,
    service_accounts_count: 10,
    sites_count: 10,
    account_admin_users_count: 1
  }

  @spec effective_limit(Portal.Account.t(), atom()) :: integer() | nil
  defp effective_limit(account, field) do
    db_value = account.limits && Map.get(account.limits, field)

    if is_nil(db_value) and plan_name(account) == "Starter" do
      Map.get(@starter_limits, field)
    else
      db_value
    end
  end

  defp billing_support_label("email"), do: "Email"
  defp billing_support_label("email_and_slack"), do: "Email & Slack"
  defp billing_support_label(_), do: "Community"

  def handle_event("close_usage_panel", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/account")}
  end

  def handle_event("handle_keydown", %{"key" => "Escape"}, %{assigns: %{usage_panel: %{}}} = socket) do
    {:noreply, push_patch(socket, to: ~p"/#{socket.assigns.account}/settings/account")}
  end

  def handle_event("handle_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("filter_usage", %{"filter" => filter}, %{assigns: %{usage_panel: %{item: item}}} = socket)
      when is_binary(filter) do
    {:noreply, assign(socket, usage_panel: load_usage_panel(socket, item, 1, filter))}
  end

  def handle_event("prev_usage_page", _params, %{assigns: %{usage_panel: %{page: page} = panel}} = socket)
      when page > 1 do
    {:noreply, assign(socket, usage_panel: load_usage_panel(socket, panel.item, page - 1, panel.filter))}
  end

  def handle_event("next_usage_page", _params, %{assigns: %{usage_panel: %{page: page, pages: pages} = panel}} = socket)
      when page < pages do
    {:noreply, assign(socket, usage_panel: load_usage_panel(socket, panel.item, page + 1, panel.filter))}
  end

  def handle_event(event, _params, socket)
      when event in ["filter_usage", "prev_usage_page", "next_usage_page"] do
    {:noreply, socket}
  end

  def handle_event("open_edit_account", _params, socket) do
    account = socket.assigns.account
    slug_history = Database.list_account_slugs(socket.assigns.subject)

    {:noreply,
     assign(socket,
       edit_account_open: true,
       slug_history: slug_history,
       account_form: to_form(account_changeset(account, %{}, slug_history))
     )}
  end

  def handle_event("close_edit_account", _params, socket) do
    {:noreply, assign(socket, edit_account_open: false)}
  end

  def handle_event("change_account", %{"account" => params}, socket) do
    changeset =
      socket.assigns.account
      |> account_changeset(params, socket.assigns.slug_history)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, account_form: to_form(changeset))}
  end

  def handle_event("submit_account", %{"account" => params}, socket) do
    account = socket.assigns.account
    slug_history = Database.list_account_slugs(socket.assigns.subject)
    changeset = account_changeset(account, params, slug_history)

    case Database.update_account(changeset, socket.assigns.subject) do
      {:ok, %{slug: slug} = updated_account} when slug != account.slug ->
        {:noreply, push_navigate(socket, to: ~p"/#{updated_account}/settings/account")}

      {:ok, updated_account} ->
        {:noreply,
         assign(socket,
           account: updated_account,
           edit_account_open: false,
           slug_history: slug_history,
           account_form: to_form(account_changeset(updated_account, %{}, slug_history))
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, account_form: to_form(changeset))}
    end
  end

  def handle_event("open_region_transfer", _params, %{assigns: %{region_transfer_enabled: true}} = socket) do
    {:noreply, assign(socket, region_transfer_open: true)}
  end

  def handle_event("open_region_transfer", _params, socket), do: {:noreply, socket}

  def handle_event("close_region_transfer", _params, socket) do
    {:noreply, assign(socket, region_transfer_open: false)}
  end

  def handle_event("request_region_transfer", _params, %{assigns: %{region_transfer_enabled: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("request_region_transfer", _params, socket) do
    %{account: account, subject: subject, data_residency_region: region} = socket.assigns
    to_region = Page.other_region(region)

    socket = assign(socket, region_transfer_open: false)

    with {:ok, :reserved} <- Database.reserve_region_transfer_request(account.id),
         {:ok, _email} <-
           account
           |> InternalEmail.region_transfer_request_email(
             subject,
             Page.data_residency_name(region),
             Page.data_residency_name(to_region)
           )
           |> Portal.Mailer.deliver() do
      {:noreply,
       put_flash(
         socket,
         :success,
         "Request sent. Firezone support will contact you at #{subject.actor.email} to schedule the transfer."
       )}
    else
      {:error, :rate_limited} ->
        {:noreply,
         put_flash(socket, :error, "You already sent a request today. Firezone support will contact you.")}

      {:error, reason} ->
        Logger.error("Failed to send region transfer request", reason: inspect(reason))
        {:noreply, put_flash(socket, :error, "Could not send the request. Please try again later.")}
    end
  end

  def handle_event("redirect_to_billing_portal", _params, socket) do
    Portal.Analytics.update_marketing_attribution(
      socket.assigns.account,
      socket.assigns.marketing_attribution
    )

    with {:ok, billing_portal_url} <-
           Billing.billing_portal_url(
             socket.assigns.account,
             url(~p"/#{socket.assigns.account}/settings/account"),
             socket.assigns.subject
           ) do
      {:noreply, redirect(socket, external: billing_portal_url)}
    else
      {:error, reason} ->
        Logger.error("Failed to get billing portal URL",
          reason: inspect(reason),
          account_id: socket.assigns.account.id
        )

        {:noreply,
         assign(socket,
           error: "Billing portal is temporarily unavailable, please try again later."
         )}
    end
  end

  def handle_event("cancel_account_deletion", _params, socket) do
    account = socket.assigns.account

    if Account.locked?(account) do
      {:noreply, assign(socket, error: "This account is locked and cannot be modified.")}
    else
      case Deletion.cancel_account_deletion(account, socket.assigns.subject) do
        {:ok, updated_account} ->
          {:noreply, assign(socket, account: updated_account, error: nil)}

        {:error, _reason} ->
          {:noreply, assign(socket, error: "Failed to cancel deletion. Please try again.")}
      end
    end
  end

  def handle_event("confirm_delete_account", _params, socket) do
    {:noreply, assign(socket, confirm_delete_account: true, error: nil)}
  end

  def handle_event("cancel_delete_account", _params, socket) do
    {:noreply, assign(socket, confirm_delete_account: false, slug_confirmation: "", error: nil)}
  end

  def handle_event("update_slug_confirmation", %{"slug_confirmation" => value}, socket) do
    {:noreply, assign(socket, slug_confirmation: value)}
  end

  def handle_event("delete_account", _params, socket) do
    account = socket.assigns.account

    cond do
      Account.locked?(account) ->
        {:noreply, assign(socket, error: "This account is locked and cannot be modified.")}

      socket.assigns.slug_confirmation == account.slug ->
        attrs = %{
          is_disabled: true,
          scheduled_deletion_at: DateTime.add(DateTime.utc_now(), 7, :day)
        }

        case Deletion.schedule_account_deletion(account, attrs, socket.assigns.subject) do
          {:ok, updated_account} ->
            {:noreply,
             assign(socket,
               account: updated_account,
               confirm_delete_account: false,
               slug_confirmation: "",
               deletion_feedback_form: deletion_feedback_form(),
               error: nil
             )}

          {:error, _reason} ->
            {:noreply,
             assign(socket, error: "Failed to schedule account deletion. Please try again.")}
        end

      true ->
        {:noreply,
         assign(socket, slug_confirmation: "", error: "Slug does not match, please try again.")}
    end
  end

  def handle_event("submit_deletion_feedback", params, socket) do
    case params |> deletion_feedback_param() |> String.trim() do
      "" ->
        :ok

      feedback ->
        Deletion.send_deletion_feedback(socket.assigns.account, feedback, socket.assigns.subject)
    end

    {:noreply, assign(socket, deletion_feedback_form: nil)}
  end

  def handle_event("skip_deletion_feedback", _params, socket) do
    {:noreply, assign(socket, deletion_feedback_form: nil)}
  end

  # The static render shows a skeleton, so the list is only loaded once, by
  # the connected mount.
  defp load_usage_panel(socket, item, page, filter) do
    %{account: account, subject: subject} = socket.assigns
    {title, description, kind} = usage_panel_text(item, account)
    filter = String.slice(String.trim(filter), 0, 100)

    {rows, total} =
      if connected?(socket) do
        list_usage_rows(item, subject, page, filter)
      else
        {nil, 0}
      end

    %{
      item: item,
      title: title,
      description: description,
      kind: kind,
      filter: filter,
      page: page,
      pages: max(1, ceil(total / @usage_page_size)),
      total: total,
      rows: rows
    }
  end

  defp list_usage_rows("sites", subject, page, filter) do
    Database.list_sites_with_gateway_counts(subject, filter, page, @usage_page_size)
  end

  defp list_usage_rows(item, subject, page, filter) do
    {types, active_only?} = usage_actor_filter(item)

    {actors, total} =
      Database.list_actors_with_last_seen(subject, types, active_only?, filter, page, @usage_page_size)

    devices = Database.list_latest_client_device_by_actor(subject, Enum.map(actors, & &1.id), active_only?)
    {Enum.map(actors, &%{actor: &1, device: Map.get(devices, &1.id)}), total}
  end

  defp usage_actor_filter("seats"), do: {[:account_user, :account_admin_user, :service_account], true}
  defp usage_actor_filter("adhoc_service_accounts"), do: {[:service_account], true}
  defp usage_actor_filter("users"), do: {[:account_user, :account_admin_user], false}
  defp usage_actor_filter("service_accounts"), do: {[:service_account], false}
  defp usage_actor_filter("admins"), do: {[:account_admin_user], false}

  defp usage_panel_text("seats", account) do
    description =
      if (account.limits.adhoc_service_accounts_count || 0) == 0 do
        "Users and service accounts with a device active in the last month, most recently active first."
      else
        "Users and service accounts with a device active in the last month, most recently active first. " <>
          "Service accounts take a seat only after the ad hoc service account allowance is used up."
      end

    {"Seats", description, :actors}
  end

  defp usage_panel_text("adhoc_service_accounts", _account) do
    {"Ad hoc Service Accounts", "Service accounts with a device active in the last month, most recently active first.",
     :actors}
  end

  defp usage_panel_text("users", _account) do
    {"Users", "Enabled users and admins, most recently active first.", :actors}
  end

  defp usage_panel_text("service_accounts", _account) do
    {"Service Accounts", "Enabled service accounts, most recently active first.", :actors}
  end

  defp usage_panel_text("admins", _account) do
    {"Admins", "Enabled admins, most recently active first.", :actors}
  end

  defp usage_panel_text("sites", _account) do
    {"Sites", "Sites you manage, with the number of gateways in each.", :sites}
  end

  defp deletion_feedback_form do
    to_form(%{"feedback" => ""}, as: :deletion_feedback)
  end

  defp deletion_feedback_param(params) do
    case get_in(params, ["deletion_feedback", "feedback"]) do
      feedback when is_binary(feedback) -> feedback
      _ -> ""
    end
  end

  defp billing_currency(:us), do: "USD"
  defp billing_currency(:eu), do: "EUR"

  defp region_transfer_enabled?(region), do: region != :on_prem

  defp account_changeset(%Account{} = account, attrs, slug_history) do
    account
    |> cast(attrs, [:name, :slug])
    |> update_change(:slug, &normalize_slug/1)
    |> Account.changeset()
    |> validate_required([:name, :slug])
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
    |> validate_change(:slug, fn :slug, slug ->
      if Portal.Repo.valid_uuid?(slug), do: [slug: "may not look like an account ID"], else: []
    end)
    |> validate_slug_change(account, slug_history)
  end

  defp validate_slug_change(changeset, account, slug_history) do
    validate_change(changeset, :slug, fn :slug, slug ->
      cond do
        not Account.slug_changes_enabled?(account) ->
          [slug: "cannot be changed on your current plan"]

        Account.locked?(account) ->
          [slug: "cannot be changed while the account is locked"]

        used_before?(slug_history, slug) ->
          []

        slug_changes_left(slug_history) == 0 ->
          [
            slug:
              "can be changed at most #{@slug_changes_per_window} times every #{@slug_change_window_days} days"
          ]

        true ->
          []
      end
    end)
  end

  defp normalize_slug(nil), do: nil
  defp normalize_slug(slug), do: slug |> String.trim() |> String.downcase()

  defp used_before?(slug_history, slug) do
    Enum.any?(slug_history, &(String.downcase(&1.slug) == slug))
  end

  # The oldest row is the slug the account started with, so it never counts
  # as a change.
  defp slug_changes_left(slug_history) do
    window_start = DateTime.add(DateTime.utc_now(), -@slug_change_window_days, :day)

    recent_changes =
      slug_history
      |> Enum.drop(1)
      |> Enum.count(&(DateTime.compare(&1.inserted_at, window_start) == :gt))

    max(@slug_changes_per_window - recent_changes, 0)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor

    @spec update_account(Ecto.Changeset.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
    def update_account(%Ecto.Changeset{data: %Account{}} = changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    @spec list_account_slugs(Portal.Authentication.Subject.t()) :: [Portal.AccountSlug.t()]
    def list_account_slugs(subject) do
      from(s in Portal.AccountSlug, order_by: [asc: s.inserted_at, asc: s.slug])
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    @spec count_account_admin_users_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_account_admin_users_for_account(subject) do
      from(a in Actor,
        where: a.is_disabled == false,
        where: a.type == :account_admin_user
      )
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    @spec count_service_accounts_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_service_accounts_for_account(subject) do
      from(a in Actor,
        where: a.is_disabled == false,
        where: a.type == :service_account
      )
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    @spec count_users_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_users_for_account(subject) do
      from(a in Actor,
        where: a.is_disabled == false,
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    @spec list_actors_with_last_seen(
            Portal.Authentication.Subject.t(),
            [atom()],
            boolean(),
            String.t(),
            pos_integer(),
            pos_integer()
          ) :: {[Actor.t()], non_neg_integer()}
    def list_actors_with_last_seen(subject, types, active_only?, filter, page, page_size) do
      stats =
        from(da in Portal.DeviceActor,
          where: da.account_id == parent_as(:actors).account_id,
          where: da.actor_id == parent_as(:actors).id,
          group_by: da.account_id,
          select: %{account_id: da.account_id, last_seen_at: max(da.last_seen_at)}
        )
        |> where_active(active_only?)

      query =
        from(a in Actor, as: :actors)
        |> where([actors: a], a.is_disabled == false and a.type in ^types)
        |> join(:left_lateral, [actors: a], s in subquery(stats), on: s.account_id == a.account_id, as: :stats)
        |> where_has_devices(active_only?)
        |> where_actor_matches(filter)

      actors =
        query
        |> order_by([actors: a, stats: s], desc_nulls_last: s.last_seen_at, asc: a.name, asc: a.id)
        |> select_merge([stats: s], %{last_seen_at: s.last_seen_at})
        |> limit(^page_size)
        |> offset(^((page - 1) * page_size))
        |> Safe.scoped(subject)
        |> Safe.all()

      {actors, query |> Safe.scoped(subject) |> Safe.aggregate(:count)}
    end

    @spec list_latest_client_device_by_actor(
            Portal.Authentication.Subject.t(),
            [Ecto.UUID.t()],
            boolean()
          ) :: %{Ecto.UUID.t() => map()}
    def list_latest_client_device_by_actor(_subject, [], _active_only?), do: %{}

    def list_latest_client_device_by_actor(subject, actor_ids, active_only?) do
      from(da in Portal.DeviceActor, as: :device_actors)
      |> where([device_actors: da], da.actor_id in ^actor_ids)
      |> where_active(active_only?)
      |> join(:inner, [device_actors: da], d in Portal.Device,
        on: d.account_id == da.account_id and d.id == da.device_id,
        as: :device
      )
      |> where([device: d], d.type == :client)
      |> distinct([device_actors: da], da.actor_id)
      |> order_by([device_actors: da, device: d], desc_nulls_last: da.last_seen_at, asc: d.id)
      |> select([device_actors: da, device: d], {
        da.actor_id,
        %{name: d.name, last_seen_user_agent: d.last_seen_user_agent}
      })
      |> Safe.scoped(subject)
      |> Safe.all()
      |> Map.new()
    end

    @spec list_sites_with_gateway_counts(
            Portal.Authentication.Subject.t(),
            String.t(),
            pos_integer(),
            pos_integer()
          ) :: {[%{site: Portal.Site.t(), gateways_count: non_neg_integer()}], non_neg_integer()}
    def list_sites_with_gateway_counts(subject, filter, page, page_size) do
      query =
        from(s in Portal.Site, as: :sites)
        |> where([sites: s], s.managed_by == :account)
        |> where_site_matches(filter)

      sites =
        query
        |> join(:left, [sites: s], sd in Portal.SiteDevice,
          on: sd.account_id == s.account_id and sd.site_id == s.id,
          as: :site_devices
        )
        |> join(:left, [site_devices: sd], d in Portal.Device,
          on: d.account_id == sd.account_id and d.id == sd.device_id and d.type == :gateway,
          as: :gateways
        )
        |> group_by([sites: s], [s.account_id, s.id])
        |> order_by([sites: s], asc: s.name, asc: s.id)
        |> select([sites: s, gateways: d], %{site: s, gateways_count: count(d.id)})
        |> limit(^page_size)
        |> offset(^((page - 1) * page_size))
        |> Safe.scoped(subject)
        |> Safe.all()

      {sites, query |> Safe.scoped(subject) |> Safe.aggregate(:count)}
    end

    defp where_actor_matches(query, ""), do: query

    defp where_actor_matches(query, filter) do
      pattern = like_pattern(filter)
      where(query, [actors: a], ilike(a.name, ^pattern) or ilike(a.email, ^pattern))
    end

    defp where_site_matches(query, ""), do: query
    defp where_site_matches(query, filter), do: where(query, [sites: s], ilike(s.name, ^like_pattern(filter)))

    defp like_pattern(filter) do
      "%" <> String.replace(filter, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
    end

    # Same window as the seat count in Portal.Billing.
    defp where_active(query, false), do: query
    defp where_active(query, true), do: where(query, [da], da.last_seen_at > ago(1, "month"))

    defp where_has_devices(query, false), do: query
    defp where_has_devices(query, true), do: where(query, [stats: s], not is_nil(s.account_id))

    @spec count_groups_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_groups_for_account(subject) do
      from(g in Portal.Site,
        where: g.managed_by == :account
      )
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    # Shares the support form's per-account budget so a stuck button cannot
    # flood support. Serialized across nodes by the row lock.
    def reserve_region_transfer_request(account_id) do
      account_id = Ecto.UUID.dump!(account_id)

      Safe.unscoped()
      |> Safe.transaction(fn ->
        query!("SELECT id FROM accounts WHERE id = $1 FOR UPDATE", [account_id])

        query!(
          "DELETE FROM feedback_submissions WHERE account_id = $1 AND inserted_at <= now() - interval '24 hours'",
          [account_id]
        )

        %{rows: [[count]]} =
          query!("SELECT count(*) FROM feedback_submissions WHERE account_id = $1", [account_id])

        if count >= 10 do
          {:error, :rate_limited}
        else
          query!(
            "INSERT INTO feedback_submissions (account_id, inserted_at) VALUES ($1, clock_timestamp())",
            [account_id]
          )

          {:ok, :reserved}
        end
      end)
    end

    defp query!(sql, params) do
      {:ok, result} = Safe.unscoped() |> Safe.query(sql, params)
      result
    end
  end
end
