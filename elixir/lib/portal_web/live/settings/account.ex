defmodule PortalWeb.Settings.Account do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Account
  alias Portal.Accounts.Deletion
  alias Portal.Billing
  alias __MODULE__.Database
  require Logger

  def mount(_params, _session, socket) do
    account = socket.assigns.account
    subject = socket.assigns.subject
    socket =
      assign(socket,
        page_title: "Account",
        billing_provisioned: Billing.account_provisioned?(account),
        billing_plan_type: Billing.plan_type(account),
        error: nil,
        slug_confirmation: "",
        confirm_delete_account: false,
        edit_account_open: false,
        name_form: to_form(Database.change_account_name(account)),
        admins_count: Database.count_account_admin_users_for_account(subject),
        service_accounts_count: Database.count_service_accounts_for_account(subject),
        users_count: Database.count_users_for_account(subject),
        active_users_count: Database.count_1m_active_users_for_account(subject),
        sites_count: Database.count_groups_for_account(subject),
        trust_anchors_enabled?: PortalWeb.NavigationComponents.trust_anchors_enabled?()
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full relative">
      <.settings_nav
        account={@account}
        current_path={@current_path}
        trust_anchors_enabled?={@trust_anchors_enabled?}
      >
        <:actions>
          <.button phx-click="open_edit_account" size="xs">
            <.icon name="ri-pencil-line" class="w-3 h-3" /> Edit
          </.button>
        </:actions>
      </.settings_nav>

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
              <dd class="text-xs text-heading">
                {@account.metadata.stripe.billing_email}
              </dd>
              <dt class="text-[10px] text-subtle mt-4">Support Type</dt>
              <dd class="text-xs text-heading capitalize">
                {billing_support_label(@account.metadata.stripe.support_type)}
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
                <.icon
                  name="ri-customer-service-2-line"
                  class="w-4 h-4 shrink-0 text-violet-500 dark:text-violet-400 mt-0.5"
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
            <.button
              :if={@billing_provisioned and @billing_plan_type != :enterprise}
              phx-click="redirect_to_billing_portal"
              size="xs"
              class="w-full mt-1"
            >
              Manage plan
            </.button>
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
            <.feature_row label="REST API" enabled={feature_enabled?(@account, :rest_api)} />
            <.feature_row
              label="Traffic Filters"
              enabled={feature_enabled?(@account, :traffic_filters)}
            />
            <.feature_row
              label="Client-to-Client"
              enabled={feature_enabled?(@account, :client_to_client)}
            />
            <.feature_row
              label="Internet Resource"
              enabled={feature_enabled?(@account, :internet_resource)}
            />
            <.feature_row
              label="Policy Conditions"
              enabled={feature_enabled?(@account, :policy_conditions)}
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
              class="mb-3 px-3 py-2 rounded border border-amber-200 bg-amber-50 text-xs text-amber-800"
            >
              You are on a paid plan. Any remaining time left on your subscription will be lost when the account is deleted.
            </div>
            <.button type="button" phx-click="cancel_account_deletion" size="xs" class="w-full">
              Cancel deletion
            </.button>
            <.flash :if={@error} kind={:error} class="mt-2">
              {@error}
            </.flash>
          </div>

          <%!-- Danger Zone (active, unlocked accounts only) --%>
          <div :if={Account.active?(@account) and not Account.locked?(@account)} class="mt-6">
            <div class="border-t border-border mb-4"></div>
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-error/60 mb-3">
              Danger Zone
            </h3>

            <button
              :if={not @confirm_delete_account}
              type="button"
              phx-click="confirm_delete_account"
              class="w-full flex items-center gap-2 px-3 py-2 rounded border border-error/20 text-xs text-error hover:bg-error-light transition-colors"
            >
              <.icon name="ri-delete-bin-line" class="w-4 h-4 shrink-0" /> Delete account
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
                  class="w-full mb-2.5 rounded border border-error/30 bg-surface px-2 py-1.5 text-xs text-heading placeholder:text-muted focus:outline-none focus:ring-1 focus:ring-error/40"
                />
                <div class="flex items-center gap-1.5">
                  <.button type="button" phx-click="cancel_delete_account" size="xs">
                    Cancel
                  </.button>
                  <.button
                    type="submit"
                    disabled={@slug_confirmation != @account.slug}
                    style="danger"
                    size="xs"
                  >
                    Delete
                  </.button>
                </div>
              </form>
              <.flash :if={@error} kind={:error} class="mt-2">
                {@error}
              </.flash>
            </div>
          </div>
        </div>

        <%!-- Right column: usage --%>
        <div class="flex-1 overflow-y-auto p-6">
          <h3 class="text-[10px] font-semibold tracking-widest uppercase text-subtle mb-4">
            Usage
          </h3>
          <div class="space-y-4 max-w-2xl">
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :monthly_active_users_count))}
              label="Monthly Active Users"
              used={@active_users_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :monthly_active_users_count))}
              label="Monthly Active Users"
              description="Users that have signed in from a device within the last month"
              used={@active_users_count}
              limit={effective_limit(@account, :monthly_active_users_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :users_count))}
              label="Users"
              used={@users_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :users_count))}
              label="Users"
              used={@users_count}
              limit={effective_limit(@account, :users_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :service_accounts_count))}
              label="Service Accounts"
              used={@service_accounts_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :service_accounts_count))}
              label="Service Accounts"
              used={@service_accounts_count}
              limit={effective_limit(@account, :service_accounts_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :account_admin_users_count))}
              label="Admins"
              used={@admins_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :account_admin_users_count))}
              label="Admins"
              used={@admins_count}
              limit={effective_limit(@account, :account_admin_users_count)}
            />
            <.usage_unlimited
              :if={is_nil(effective_limit(@account, :sites_count))}
              label="Sites"
              used={@sites_count}
            />
            <.usage_bar
              :if={not is_nil(effective_limit(@account, :sites_count))}
              label="Sites"
              used={@sites_count}
              limit={effective_limit(@account, :sites_count)}
            />
          </div>
        </div>
      </div>

      <.edit_account_panel open={@edit_account_open} form={@name_form} />
    </div>
    """
  end

  defp feature_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon
        :if={@enabled}
        name="ri-check-line"
        class="w-3.5 h-3.5 shrink-0 text-success"
      />
      <.icon
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
          @over? && "text-red-500",
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
            @over? && "bg-red-500",
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
        <.icon_button icon="ri-close-line" title="Close (Esc)" phx-click="close_edit_account" />
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
          <.input
            field={@form[:name]}
            label="Account Name"
            phx-debounce="300"
          />
        </div>

        <div class="flex items-center justify-end gap-2 px-5 py-4 border-t border-border">
          <.button type="button" phx-click="close_edit_account" size="xs">
            Cancel
          </.button>
          <.button type="submit" style="primary" disabled={not @form.source.valid?} size="xs">
            Save
          </.button>
        </div>
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

  def handle_event("redirect_to_billing_portal", _params, socket) do
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
          disabled_at: DateTime.utc_now(),
          scheduled_deletion_at: DateTime.add(DateTime.utc_now(), 7, :day)
        }

        case Deletion.schedule_account_deletion(account, attrs, socket.assigns.subject) do
          {:ok, updated_account} ->
            {:noreply,
             assign(socket,
               account: updated_account,
               confirm_delete_account: false,
               slug_confirmation: "",
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

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.Safe
    alias Portal.Account
    alias Portal.Actor
    alias Portal.Device

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
        where: is_nil(a.disabled_at),
        where: a.type == :account_admin_user
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.aggregate(:count)
    end

    @spec count_service_accounts_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_service_accounts_for_account(subject) do
      from(a in Actor,
        where: is_nil(a.disabled_at),
        where: a.type == :service_account
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.aggregate(:count)
    end

    @spec count_users_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_users_for_account(subject) do
      from(a in Actor,
        where: is_nil(a.disabled_at),
        where: a.type in [:account_admin_user, :account_user]
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.aggregate(:count)
    end

    @spec count_1m_active_users_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_1m_active_users_for_account(subject) do
      from(d in Device, as: :devices)
      |> join(:inner, [devices: d], s in Portal.ClientSession,
        on: s.device_id == d.id and s.account_id == d.account_id,
        as: :session
      )
      |> where([devices: d], d.type == :client)
      |> where([session: s], s.inserted_at > ago(1, "month"))
      |> join(:inner, [devices: d], a in Actor,
        on: d.actor_id == a.id and d.account_id == a.account_id,
        as: :actor
      )
      |> where([actor: a], is_nil(a.disabled_at))
      |> where([actor: a], a.type in [:account_user, :account_admin_user])
      |> select([devices: d], d.actor_id)
      |> distinct(true)
      |> Safe.scoped(subject, :replica)
      |> Safe.aggregate(:count)
    end

    @spec count_groups_for_account(Portal.Authentication.Subject.t()) :: integer()
    def count_groups_for_account(subject) do
      from(g in Portal.Site,
        where: g.managed_by == :account
      )
      |> Safe.scoped(subject, :replica)
      |> Safe.aggregate(:count)
    end
  end
end
