defmodule PortalWeb.Settings.Account do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Account
  alias Portal.Accounts.Deletion
  alias Portal.Billing
  alias Portal.Mailer.InternalEmail
  alias PortalWeb.Settings.Components, as: SettingsComponents
  alias __MODULE__.Database
  require Logger

  def mount(_params, session, socket) do
    account = socket.assigns.account

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
        name_form: to_form(Database.change_account_name(account)),
        usage: if(connected?(socket), do: load_usage(account, socket.assigns.subject))
      )

    {:ok, socket}
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
    <div class="flex flex-col h-full relative">
      <Navigation.settings_nav
        account={@account}
        current_path={@current_path}
      >
        <:actions>
          <Form.button phx-click="open_edit_account" size="xs">
            <Core.icon name="ri-pencil-line" class="w-3 h-3" /> Edit
          </Form.button>
        </:actions>
      </Navigation.settings_nav>

      <%!-- Two-column body --%>
      <div class="flex flex-1 bg-surface overflow-hidden">
        <%!-- Left column: plan + features + danger zone --%>
        <div class="w-80 shrink-0 border-r border-border p-6 overflow-y-auto">
          <%!-- Plan card --%>
          <div class="rounded border border-border bg-raised p-4 space-y-3">
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs font-semibold tracking-widest uppercase text-subtle">
                Plan
              </span>
              <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-violet-100 text-violet-700 dark:bg-violet-900/40 dark:text-violet-300">
                {plan_name(@account)}
              </span>
            </div>
            <dl
              :if={@billing_provisioned}
              class="space-y-1.5 pt-2 border-t border-border"
            >
              <dt class="text-[10px] text-subtle">Billing Email</dt>
              <dd class="text-xs text-body font-medium">
                {@account.metadata.stripe.billing_email}
              </dd>
              <dt class="text-[10px] text-subtle mt-4">Support Type</dt>
              <dd class="text-xs text-body capitalize font-medium">
                {billing_support_label(@account.metadata.stripe.support_type)}
              </dd>
              <dt :if={@account.metadata.stripe.add_ons != []} class="text-[10px] text-subtle mt-4">
                Add-ons
              </dt>
              <dd
                :for={add_on <- @account.metadata.stripe.add_ons}
                class="text-xs text-body font-medium flex justify-between gap-2"
              >
                <span>{add_on.name}</span>
                <span class="tabular-nums">× {add_on.quantity}</span>
              </dd>
            </dl>
            <p
              :if={not @billing_provisioned}
              class="text-xs text-subtle pt-2 border-t border-border"
            >
              This account has not had billing provisioned.
            </p>
            <div
              :if={@billing_provisioned and @billing_plan_type == :enterprise}
              class="pt-2 border-t border-border"
            >
              <div class="rounded-lg border border-violet-200 bg-violet-50 dark:border-violet-800 dark:bg-violet-950/30 p-3 flex gap-2.5 items-start">
                <Core.icon
                  name="ri-customer-service-2-line"
                  class="w-4 h-4 shrink-0 text-link mt-0.5"
                />
                <div>
                  <p class="text-xs font-medium text-violet-700 dark:text-violet-300">
                    Enterprise Plan
                  </p>
                  <p class="text-xs text-violet-600 dark:text-violet-400 mt-0.5">
                    Contact your account manager for plan changes.
                  </p>
                </div>
              </div>
            </div>
            <Form.button
              :if={@billing_provisioned and @billing_plan_type != :enterprise}
              phx-click="redirect_to_billing_portal"
              size="xs"
              class="w-full mt-1"
            >
              Manage plan
            </Form.button>
          </div>

          <%!-- Plan features (always shown) --%>
          <div class="mt-6 space-y-1.5">
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-2">
              Plan Features
            </h3>
            <.feature_row
              label="Identity Provider Sync"
              enabled={feature_enabled?(@account, :idp_sync)}
            />
            <.feature_row
              label="Internet Resource"
              enabled={feature_enabled?(@account, :internet_resource)}
            />
            <.feature_row
              label="Policy Conditions"
              enabled={feature_enabled?(@account, :policy_conditions)}
            />
            <.feature_row label="Log Sinks" enabled={feature_enabled?(@account, :log_sinks)} />
            <.feature_row
              label="Device Posture"
              enabled={feature_enabled?(@account, :device_posture)}
            />
          </div>

          <%!-- Actions (pending deletion, self-initiated, not locked) --%>
          <div
            :if={not Account.locked?(@account) and Account.pending_deletion?(@account)}
            class="mt-6"
          >
            <div class="border-t border-border mb-4"></div>
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-3">
              Actions
            </h3>
            <p class="text-xs text-body mb-3">
              This account is scheduled for deletion on <strong>{Calendar.strftime(@account.scheduled_deletion_at, "%B %-d, %Y")}</strong>.
            </p>
            <div
              :if={Portal.Billing.paid_plan?(@account)}
              class="mb-3 px-3 py-2 rounded border border-warning/30 bg-warning-light text-xs text-warning"
            >
              You are on a paid plan. Any remaining time left on your subscription will be lost when the account is deleted.
            </div>
            <Form.button type="button" phx-click="cancel_account_deletion" size="xs" class="w-full">
              Cancel deletion
            </Form.button>
            <Core.flash :if={@error} kind={:error} class="mt-2">
              {@error}
            </Core.flash>
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

          <%!-- Danger Zone (active, unlocked accounts only) --%>
          <div :if={Account.active?(@account) and not Account.locked?(@account)} class="mt-6">
            <div class="border-t border-border mb-4"></div>
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error mb-3">
              Danger Zone
            </h3>

            <button
              :if={not @confirm_delete_account}
              type="button"
              phx-click="confirm_delete_account"
              class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
            >
              <Core.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete account
            </button>

            <div
              :if={@confirm_delete_account}
              class="px-3 py-2.5 rounded border border-error/20 bg-error-light"
            >
              <p class="text-xs font-medium text-error mb-1">
                Delete this account?
              </p>
              <p class="text-xs text-error/70 mb-3">
                This will <strong>immediately disable</strong>
                your account and <strong>permanently delete</strong>
                all data after 7 days.
              </p>
              <p class="text-xs text-error/70 mb-1.5">
                Type <strong>{@account.slug}</strong> to confirm:
              </p>
              <form id="delete-account-form" phx-change="update_slug_confirmation" phx-submit="delete_account">
                <input
                  type="text"
                  name="slug_confirmation"
                  value={@slug_confirmation}
                  placeholder={@account.slug}
                  autocomplete="off"
                  class="w-full mb-2.5 rounded border border-error/30 bg-surface px-2 py-1.5 text-xs text-heading placeholder:text-subtle focus:outline-none focus:ring-1 focus:ring-error/40"
                />
                <div class="flex items-center gap-1.5">
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
        </div>

        <%!-- Right column: usage --%>
        <div class="flex-1 overflow-y-auto p-6">
          <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-4">
            Usage
          </h3>
          <SettingsComponents.skeleton :if={is_nil(@usage)} id="usage-skeleton" rows={3} class="max-w-2xl" />
          <div :if={@usage} id="usage" class="space-y-4 max-w-2xl">
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :monthly_active_users_count))}
              label="Seats"
              description="Users and service accounts with a device active in the last month"
              used={@usage.active_users_count}
              limit={effective_limit(@account, :monthly_active_users_count)}
            />
            <.usage_bar
              :if={(effective_limit(@account, :adhoc_service_accounts_count) || 0) > 0}
              label="Ad hoc Service Accounts"
              description="Active service accounts that do not take a seat"
              used={@usage.adhoc_service_accounts_count}
              limit={effective_limit(@account, :adhoc_service_accounts_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :users_count))}
              label="Users"
              used={@usage.users_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :users_count))}
              label="Users"
              used={@usage.users_count}
              limit={effective_limit(@account, :users_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :service_accounts_count))}
              label="Service Accounts"
              used={@usage.service_accounts_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :service_accounts_count))}
              label="Service Accounts"
              used={@usage.service_accounts_count}
              limit={effective_limit(@account, :service_accounts_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :account_admin_users_count))}
              label="Admins"
              used={@usage.admins_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :account_admin_users_count))}
              label="Admins"
              used={@usage.admins_count}
              limit={effective_limit(@account, :account_admin_users_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :sites_count))}
              label="Sites"
              used={@usage.sites_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :sites_count))}
              label="Sites"
              used={@usage.sites_count}
              limit={effective_limit(@account, :sites_count)}
            />
          </div>

          <div :if={@data_residency_region != :on_prem} id="data-residency" class="mt-8 max-w-2xl">
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-4">
              Data Residency
            </h3>
            <div class="rounded border border-border bg-raised p-4 space-y-3">
              <div class="flex items-center gap-2">
                <Page.residency_flag region={@data_residency_region} />
                <span class="text-sm text-body font-medium">
                  Cloud region: <strong>{Page.data_residency_name(@data_residency_region)}</strong>
                </span>
              </div>
              <p class="text-xs text-subtle">Your account data is stored in:</p>
              <ul class="text-xs text-body space-y-1">
                <li
                  :for={{city, country} <- Page.data_residency_locations(@data_residency_region)}
                  class="flex items-center gap-1.5"
                >
                  <Core.icon name="ri-map-pin-line" class="w-3.5 h-3.5 text-subtle" />
                  {city}, {country}
                </li>
              </ul>
              <p class="text-xs text-subtle">
                <a
                  href="https://www.firezone.dev/kb/architecture/regional-availability"
                  target="_blank"
                  rel="noopener"
                  class={Core.link_style()}
                >
                  Learn more about Firezone Cloud regions.
                </a>
              </p>
              <div :if={@region_transfer_enabled} class="pt-3 border-t border-border">
                <Form.button id="request-region-transfer" phx-click="open_region_transfer" size="xs">
                  Request transfer to the {Page.data_residency_name(Page.other_region(@data_residency_region))} region
                </Form.button>
              </div>
            </div>
          </div>

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
              <div class="space-y-3 text-sm text-body">
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
                  redirects to the new one. Each Gateway needs a new token and the new API URL
                  before it comes back online. Headless Clients need new service account tokens.
                  Recreate every API token and reconnect your MCP clients.
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
        </div>
      </div>

      <.edit_account_panel open={@edit_account_open} form={@name_form} />
    </div>
    """
  end

  defp feature_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <Core.icon
        :if={@enabled}
        name="ri-check-line"
        class="w-3.5 h-3.5 shrink-0 text-success"
      />
      <Core.icon
        :if={not @enabled}
        name="ri-subtract-line"
        class="w-3.5 h-3.5 shrink-0 text-subtle"
      />
      <span class={[
        "text-xs",
        @enabled && "text-heading",
        not @enabled && "text-subtle"
      ]}>
        {@label}
      </span>
    </div>
    """
  end

  defp usage_bar(assigns) do
    assigns = assign_new(assigns, :description, fn -> nil end)

    over? =
      is_integer(assigns.used) and is_integer(assigns.limit) and assigns.used > assigns.limit

    assigns = assign(assigns, :over?, over?)

    ~H"""
    <div>
      <div class="flex items-baseline justify-between mb-1.5">
        <div class="flex items-center gap-1.5 min-w-0">
          <span class="text-xs font-medium text-heading">{@label}</span>
          <span :if={@description} class="text-xs text-subtle truncate">
            — {@description}
          </span>
        </div>
        <span class={[
          "text-xs tabular-nums shrink-0 ml-4",
          @over? && "text-danger",
          not @over? && "text-body"
        ]}>
          {@used} / {@limit}
        </span>
      </div>
      <div class="h-1.5 rounded-full bg-raised border border-border overflow-hidden">
        <div
          id={"progress-#{@label |> String.downcase() |> String.replace(" ", "-")}"}
          phx-hook="ProgressBar"
          data-pct={bar_pct(@used, @limit)}
          class={[
            "h-full rounded-full transition-all",
            @over? && "bg-danger",
            not @over? && "bg-brand"
          ]}
        >
        </div>
      </div>
    </div>
    """
  end

  defp usage_unlimited(assigns) do
    ~H"""
    <div>
      <div class="flex items-baseline justify-between mb-1.5">
        <span class="text-xs font-medium text-heading">{@label}</span>
        <span class="text-xs tabular-nums shrink-0 ml-4 text-body">
          {@used} used · <span class="text-subtle">Unlimited</span>
        </span>
      </div>
      <div class="h-1.5 rounded-full bg-raised border border-border overflow-hidden">
      </div>
    </div>
    """
  end

  defp bar_pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    min(div(used * 100, limit), 100)
  end

  defp bar_pct(_, _), do: 0

  attr :open, :boolean, required: true
  attr :form, :any, required: true

  defp edit_account_panel(assigns) do
    ~H"""
    <div class={[
      "absolute inset-y-0 right-0 z-20",
      "w-full lg:w-3/4 xl:w-96",
      "flex flex-col bg-surface border-l border-border shadow-xl",
      "transition-transform duration-200",
      @open && "translate-x-0",
      not @open && "translate-x-full"
    ]}>
      <div class="flex items-center justify-between px-5 py-4 border-b border-border">
        <h2 class="text-sm font-semibold text-heading">Edit Account</h2>
        <Form.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_edit_account" />
      </div>

      <.form
        id="account-name-form"
        for={@form}
        phx-change="change_account_name"
        phx-submit="submit_account_name"
        as={:account}
        class="flex flex-col flex-1 overflow-hidden"
      >
        <div class="flex-1 overflow-y-auto p-5">
          <Form.input
            field={@form[:name]}
            label="Account Name"
            phx-debounce="300"
          />
        </div>

        <Form.panel_footer>
          <Form.panel_footer_button type="button" phx-click="close_edit_account">
            Cancel
          </Form.panel_footer_button>
          <Form.panel_footer_button type="submit" style="primary" disabled={not @form.source.valid?}>
            Save
          </Form.panel_footer_button>
        </Form.panel_footer>
      </.form>
    </div>
    """
  end

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

  def handle_event("open_edit_account", _params, socket) do
    account = socket.assigns.account

    {:noreply,
     assign(socket,
       edit_account_open: true,
       name_form: to_form(Database.change_account_name(account))
     )}
  end

  def handle_event("close_edit_account", _params, socket) do
    {:noreply, assign(socket, edit_account_open: false)}
  end

  def handle_event("change_account_name", %{"account" => params}, socket) do
    changeset =
      socket.assigns.account
      |> Database.change_account_name(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, name_form: to_form(changeset))}
  end

  def handle_event("submit_account_name", %{"account" => params}, socket) do
    account = socket.assigns.account
    subject = socket.assigns.subject

    case Database.update_account_name(account, params, subject) do
      {:ok, updated_account} ->
        {:noreply,
         assign(socket,
           account: updated_account,
           edit_account_open: false,
           name_form: to_form(Database.change_account_name(updated_account))
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, name_form: to_form(changeset))}
    end
  end

  def handle_event("open_region_transfer", _params, socket) do
    {:noreply, assign(socket, region_transfer_open: true)}
  end

  def handle_event("close_region_transfer", _params, socket) do
    {:noreply, assign(socket, region_transfer_open: false)}
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

  defp region_transfer_enabled?(region), do: region in [:us, :eu]

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor

    @spec update_account_name(Account.t(), map(), Portal.Authentication.Subject.t()) ::
            {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
    def update_account_name(%Account{} = account, attrs, subject) do
      account
      |> cast(attrs, [:name])
      |> Account.changeset()
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    @spec change_account_name(Account.t(), map()) :: Ecto.Changeset.t()
    def change_account_name(%Account{} = account, attrs \\ %{}) do
      account
      |> cast(attrs, [:name])
      |> Account.changeset()
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
