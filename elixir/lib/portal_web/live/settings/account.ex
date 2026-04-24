defmodule PortalWeb.Settings.Account do
  use PortalWeb, :live_view
  import Ecto.Changeset
  alias Portal.Account
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
        error: nil,
        slug_confirmation: "",
        confirm_delete_account: false,
        admins_count: Database.count_account_admin_users_for_account(subject),
        service_accounts_count: Database.count_service_accounts_for_account(subject),
        users_count: Database.count_users_for_account(subject),
        active_users_count: Database.count_1m_active_users_for_account(subject),
        sites_count: Database.count_groups_for_account(subject)
      )

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <.settings_nav account={@account} current_path={@current_path} />

      <%!-- Two-column body --%>
      <div class="flex flex-1 bg-[var(--surface)] overflow-hidden">
        <%!-- Left column: plan + features + danger zone --%>
        <div class="w-80 shrink-0 border-r border-[var(--border)] p-6 overflow-y-auto">
          <%!-- Plan card --%>
          <div class="rounded border border-[var(--border)] bg-[var(--surface-raised)] p-4 space-y-3">
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs font-semibold tracking-widest uppercase text-[var(--text-tertiary)]">
                Plan
              </span>
              <span class="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-violet-100 text-violet-700 dark:bg-violet-900/40 dark:text-violet-300">
                {plan_name(@account)}
              </span>
            </div>
            <dl
              :if={@billing_provisioned}
              class="space-y-1.5 pt-2 border-t border-[var(--border)]"
            >
              <dt class="text-[10px] text-[var(--text-tertiary)]">Billing Email</dt>
              <dd class="text-xs text-[var(--text-primary)]">
                {@account.metadata.stripe.billing_email}
              </dd>
              <dt class="text-[10px] text-[var(--text-tertiary)] mt-4">Support Type</dt>
              <dd class="text-xs text-[var(--text-primary)] capitalize">
                {billing_support_label(@account.metadata.stripe.support_type)}
              </dd>
            </dl>
            <p
              :if={not @billing_provisioned}
              class="text-xs text-[var(--text-tertiary)] pt-2 border-t border-[var(--border)]"
            >
              This account has not had billing provisioned.
            </p>
            <button
              :if={@billing_provisioned}
              phx-click="redirect_to_billing_portal"
              class="w-full mt-1 px-3 py-1.5 rounded text-xs font-medium border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Upgrade plan
            </button>
          </div>

          <%!-- Plan features (always shown) --%>
          <div class="mt-6 space-y-1.5">
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-2">
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
            <div class="border-t border-[var(--border)] mb-4"></div>
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-3">
              Actions
            </h3>
            <p class="text-xs text-[var(--text-secondary)] mb-3">
              This account is scheduled for deletion on <strong>{Calendar.strftime(@account.scheduled_deletion_at, "%B %-d, %Y")}</strong>.
            </p>
            <button
              type="button"
              phx-click="cancel_account_deletion"
              class="w-full text-left px-3 py-2 rounded border border-[var(--border-strong)] text-xs text-[var(--text-secondary)] hover:text-[var(--text-primary)] hover:border-[var(--border-emphasis)] bg-[var(--surface)] transition-colors"
            >
              Cancel deletion
            </button>
            <.flash :if={@error} kind={:error} class="mt-2">
              {@error}
            </.flash>
          </div>

          <%!-- Danger Zone (active, unlocked accounts only) --%>
          <div :if={Account.active?(@account) and not Account.locked?(@account)} class="mt-6">
            <div class="border-t border-[var(--border)] mb-4"></div>
            <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--status-error)]/60 mb-3">
              Danger Zone
            </h3>

            <button
              :if={not @confirm_delete_account}
              type="button"
              phx-click="confirm_delete_account"
              class="w-full text-left px-3 py-2 rounded border border-[var(--status-error)]/20 text-xs text-[var(--status-error)] hover:bg-[var(--status-error-bg)] transition-colors"
            >
              Delete account
            </button>

            <div
              :if={@confirm_delete_account}
              class="px-3 py-2.5 rounded border border-[var(--status-error)]/20 bg-[var(--status-error-bg)]"
            >
              <p class="text-xs font-medium text-[var(--status-error)] mb-1">
                Delete this account?
              </p>
              <p class="text-xs text-[var(--status-error)]/70 mb-3">
                This will <strong>immediately disable</strong>
                your account and <strong>permanently delete</strong>
                all data after 7 days.
              </p>
              <p class="text-xs text-[var(--status-error)]/70 mb-1.5">
                Type <strong>{@account.slug}</strong> to confirm:
              </p>
              <form phx-change="update_slug_confirmation" phx-submit="delete_account">
                <input
                  type="text"
                  name="slug_confirmation"
                  value={@slug_confirmation}
                  placeholder={@account.slug}
                  autocomplete="off"
                  class="w-full mb-2.5 rounded border border-[var(--status-error)]/30 bg-[var(--surface)] px-2 py-1.5 text-xs text-[var(--text-primary)] placeholder:text-[var(--text-muted)] focus:outline-none focus:ring-1 focus:ring-[var(--status-error)]/40"
                />
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    phx-click="cancel_delete_account"
                    class="px-2 py-1 text-xs rounded border border-[var(--border-strong)] text-[var(--text-secondary)] hover:text-[var(--text-primary)] bg-[var(--surface)] transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    disabled={@slug_confirmation != @account.slug}
                    class="px-2 py-1 text-xs rounded border border-[var(--status-error)]/40 text-[var(--status-error)] hover:bg-[var(--status-error)]/10 bg-[var(--surface)] transition-colors font-medium disabled:opacity-40 disabled:cursor-not-allowed"
                  >
                    Delete
                  </button>
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
          <h3 class="text-[10px] font-semibold tracking-widest uppercase text-[var(--text-tertiary)] mb-4">
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
    </div>
    """
  end

  defp feature_row(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <.icon
        :if={@enabled}
        name="ri-check-line"
        class="w-3.5 h-3.5 shrink-0 text-[var(--status-active)]"
      />
      <.icon
        :if={not @enabled}
        name="ri-subtract-line"
        class="w-3.5 h-3.5 shrink-0 text-[var(--text-tertiary)]"
      />
      <span class={[
        "text-xs",
        @enabled && "text-[var(--text-primary)]",
        not @enabled && "text-[var(--text-tertiary)]"
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
          <span class="text-xs font-medium text-[var(--text-primary)]">{@label}</span>
          <span :if={@description} class="text-xs text-[var(--text-tertiary)] truncate">
            — {@description}
          </span>
        </div>
        <span class={[
          "text-xs tabular-nums shrink-0 ml-4",
          @over? && "text-red-500",
          not @over? && "text-[var(--text-secondary)]"
        ]}>
          {@used} / {@limit}
        </span>
      </div>
      <div class="h-1.5 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] overflow-hidden">
        <div
          id={"progress-#{@label |> String.downcase() |> String.replace(" ", "-")}"}
          phx-hook="ProgressBar"
          data-pct={bar_pct(@used, @limit)}
          class={[
            "h-full rounded-full transition-all",
            @over? && "bg-red-500",
            not @over? && "bg-[var(--brand)]"
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
        <span class="text-xs font-medium text-[var(--text-primary)]">{@label}</span>
        <span class="text-xs tabular-nums shrink-0 ml-4 text-[var(--text-secondary)]">
          {@used} used · <span class="text-[var(--text-tertiary)]">Unlimited</span>
        </span>
      </div>
      <div class="h-1.5 rounded-full bg-[var(--surface-raised)] border border-[var(--border)] overflow-hidden">
      </div>
    </div>
    """
  end

  defp bar_pct(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    min(div(used * 100, limit), 100)
  end

  defp bar_pct(_, _), do: 0

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
      case Database.cancel_account_deletion(account, socket.assigns.subject) do
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

        case Database.schedule_account_deletion(account, attrs, socket.assigns.subject) do
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

    @spec cancel_account_deletion(Account.t(), Portal.Authentication.Subject.t()) ::
            {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
    def cancel_account_deletion(%Account{} = account, subject) do
      account
      |> cast(%{disabled_at: nil, scheduled_deletion_at: nil}, [
        :disabled_at,
        :scheduled_deletion_at
      ])
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    @spec schedule_account_deletion(Account.t(), map(), Portal.Authentication.Subject.t()) ::
            {:ok, Account.t()} | {:error, Ecto.Changeset.t()}
    def schedule_account_deletion(%Account{} = account, attrs, subject) do
      account
      |> cast(attrs, [:disabled_at, :scheduled_deletion_at])
      |> Safe.scoped(subject)
      |> Safe.update()
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
