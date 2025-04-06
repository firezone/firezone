defmodule Domain.Accounts do
  alias Web.Settings.Account
  alias Domain.{Repo, Config, PubSub}
  alias Domain.{Auth, Billing}
  alias Domain.Accounts.{Account, Features, Authorizer}

  def all_active_accounts! do
    Account.Query.not_disabled()
    |> Repo.all()
  end

  def all_accounts_by_ids!(ids) do
    if Enum.all?(ids, &Repo.valid_uuid?/1) do
      Account.Query.not_deleted()
      |> Account.Query.by_id({:in, ids})
      |> Repo.all()
    else
      []
    end
  end

  def all_active_paid_accounts_pending_notification! do
    ["Team", "Enterprise"]
    |> Enum.flat_map(&all_active_accounts_by_subscription_name_pending_notification!/1)
  end

  def all_active_accounts_by_subscription_name_pending_notification!(subscription_name) do
    Account.Query.not_disabled()
    |> Account.Query.by_stripe_product_name(subscription_name)
    |> Account.Query.by_notification_enabled("outdated_gateway")
    |> Account.Query.by_notification_last_notified("outdated_gateway", 24)
    |> Repo.all()
  end

  def fetch_account_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_account_permission()),
         true <- Repo.valid_uuid?(id) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Account.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_account_by_id_or_slug(term, opts \\ [])
  def fetch_account_by_id_or_slug(nil, _opts), do: {:error, :not_found}
  def fetch_account_by_id_or_slug("", _opts), do: {:error, :not_found}

  def fetch_account_by_id_or_slug(id_or_slug, opts) do
    Account.Query.not_deleted()
    |> Account.Query.by_id_or_slug(id_or_slug)
    |> Repo.fetch(Account.Query, opts)
  end

  def fetch_account_by_id!(id) do
    Account.Query.not_deleted()
    |> Account.Query.by_id(id)
    |> Repo.one!()
  end

  def create_account(attrs) do
    Account.Changeset.create(attrs)
    |> Repo.insert()
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.Changeset.update(account, attrs)
  end

  def update_account(%Account{} = account, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_account_permission()) do
      Account.Query.not_deleted()
      |> Account.Query.by_id(account.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(Account.Query,
        with: &Account.Changeset.update_profile_and_config(&1, attrs),
        after_commit: &on_account_update/2
      )
    end
  end

  def update_account(%Account{} = account, attrs) do
    update_account_by_id(account.id, attrs)
  end

  def update_account_by_id(id, attrs) do
    Account.Query.all()
    |> Account.Query.by_id(id)
    |> Repo.fetch_and_update(Account.Query,
      with: &Account.Changeset.update(&1, attrs),
      after_commit: &on_account_update/2
    )
    |> case do
      {:ok, %{disabled_at: nil} = account} ->
        {:ok, account}

      {:ok, account} ->
        :ok = Domain.Clients.disconnect_account_clients(account)
        {:ok, account}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def current_plan(%Account{metadata: %{stripe: %{product_name: plan}}}) when is_binary(plan) do
    plan
  end

  def current_plan(%Account{}) do
    "Starter"
  end

  # Limits and Features

  def users_limit_exceeded?(%Accounts.Account{} = account, users_count) do
    not is_nil(account.limits.users_count) and
      users_count > account.limits.users_count
  end

  def seats_limit_exceeded?(%Accounts.Account{} = account, active_users_count) do
    not is_nil(account.limits.monthly_active_users_count) and
      active_users_count > account.limits.monthly_active_users_count
  end

  def can_create_users?(%Accounts.Account{} = account) do
    users_count = Actors.count_users_for_account(account)
    active_users_count = Clients.count_1m_active_users_for_account(account)

    cond do
      not Accounts.account_active?(account) ->
        false

      not is_nil(account.limits.monthly_active_users_count) ->
        active_users_count < account.limits.monthly_active_users_count

      not is_nil(account.limits.users_count) ->
        users_count < account.limits.users_count

      true ->
        true
    end
  end

  def service_accounts_limit_exceeded?(%Accounts.Account{} = account, service_accounts_count) do
    not is_nil(account.limits.service_accounts_count) and
      service_accounts_count > account.limits.service_accounts_count
  end

  def can_create_service_accounts?(%Accounts.Account{} = account) do
    service_accounts_count = Actors.count_service_accounts_for_account(account)

    Accounts.account_active?(account) and
      (is_nil(account.limits.service_accounts_count) or
         service_accounts_count < account.limits.service_accounts_count)
  end

  def gateway_groups_limit_exceeded?(%Accounts.Account{} = account, gateway_groups_count) do
    not is_nil(account.limits.gateway_groups_count) and
      gateway_groups_count > account.limits.gateway_groups_count
  end

  def can_create_gateway_groups?(%Accounts.Account{} = account) do
    gateway_groups_count = Gateways.count_groups_for_account(account)

    Accounts.account_active?(account) and
      (is_nil(account.limits.gateway_groups_count) or
         gateway_groups_count < account.limits.gateway_groups_count)
  end

  def admins_limit_exceeded?(%Accounts.Account{} = account, account_admins_count) do
    not is_nil(account.limits.account_admin_users_count) and
      account_admins_count > account.limits.account_admin_users_count
  end

  def can_create_admin_users?(%Accounts.Account{} = account) do
    account_admins_count = Actors.count_account_admin_users_for_account(account)

    Accounts.account_active?(account) and
      (is_nil(account.limits.account_admin_users_count) or
         account_admins_count < account.limits.account_admin_users_count)
  end

  defp on_account_update(account, changeset) do
    :ok = Billing.on_account_update(account, changeset)

    if Ecto.Changeset.changed?(changeset, :config) do
      broadcast_config_update_to_account(account)
    else
      :ok
    end
  end

  for feature <- Features.__schema__(:fields) do
    def unquote(:"#{feature}_enabled?")(account) do
      Config.global_feature_enabled?(unquote(feature)) and
        account_feature_enabled?(account, unquote(feature))
    end
  end

  defp account_feature_enabled?(account, feature) do
    Map.fetch!(account.features || %Features{}, feature) || false
  end

  def account_active?(%{deleted_at: nil, disabled_at: nil}), do: true
  def account_active?(_account), do: false

  def ensure_has_access_to(%Auth.Subject{} = subject, %Account{} = account) do
    if subject.account.id == account.id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  def generate_unique_slug do
    slug_candidate = Domain.NameGenerator.generate_slug()

    queryable =
      Account.Query.not_deleted()
      |> Account.Query.by_slug(slug_candidate)

    if Repo.exists?(queryable) do
      generate_unique_slug()
    else
      slug_candidate
    end
  end

  def type(%Account{metadata: %{stripe: %{product_name: type}}}) do
    type || "Starter"
  end

  def type(%Account{}) do
    "Starter"
  end

  ### PubSub

  defp account_topic(%Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "accounts:#{account_id}"

  def subscribe_to_events_in_account(account_or_id) do
    account_or_id |> account_topic() |> PubSub.subscribe()
  end

  def unsubscribe_from_events_in_account(account_or_id) do
    account_or_id |> account_topic() |> PubSub.unsubscribe()
  end

  defp broadcast_config_update_to_account(%Account{} = account) do
    broadcast_to_account(account.id, :config_changed)
  end

  defp broadcast_to_account(account_or_id, payload) do
    account_or_id
    |> account_topic()
    |> PubSub.broadcast(payload)
  end
end
