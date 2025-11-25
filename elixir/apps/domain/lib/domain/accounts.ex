defmodule Domain.Accounts do
  alias Web.Settings.Account
  alias Domain.{Repo, Config, Safe}
  alias Domain.{Auth, Billing}
  alias Domain.Accounts.{Account, Features}

  def all_active_accounts! do
    Account.Query.not_disabled()
    |> Safe.unscoped()
    |> Safe.all()
  end

  def all_accounts_by_ids!(ids) do
    if Enum.all?(ids, &Repo.valid_uuid?/1) do
      Account.Query.all()
      |> Account.Query.by_id({:in, ids})
      |> Safe.unscoped()
      |> Safe.all()
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
    |> Safe.unscoped()
    |> Safe.all()
  end

  # TODO: This will need to be updated once more notifications are available
  def all_accounts_pending_notification! do
    Account.Query.not_disabled()
    |> Account.Query.by_notification_enabled("outdated_gateway")
    |> Account.Query.by_notification_last_notified("outdated_gateway", 24)
    |> Safe.unscoped()
    |> Safe.all()
  end

  def fetch_account_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Account.Query.all()
        |> Account.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        account -> {:ok, account}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_account_by_id_or_slug(term, opts \\ [])
  def fetch_account_by_id_or_slug(nil, _opts), do: {:error, :not_found}
  def fetch_account_by_id_or_slug("", _opts), do: {:error, :not_found}

  def fetch_account_by_id_or_slug(id_or_slug, opts) do
    Account.Query.all()
    |> Account.Query.by_id_or_slug(id_or_slug)
    |> Repo.fetch(Account.Query, opts)
  end

  def fetch_account_by_id!(id) do
    Account.Query.all()
    |> Account.Query.by_id(id)
    |> Safe.unscoped()
    |> Safe.one!()
  end

  def create_account(attrs) do
    Account.Changeset.create(attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def change_account(%Account{} = account, attrs \\ %{}) do
    Account.Changeset.update(account, attrs)
  end

  def update_account(%Account{} = account, attrs, %Auth.Subject{} = subject) do
    changeset = Account.Changeset.update_profile_and_config(account, attrs)

    case Safe.scoped(changeset, subject) |> Safe.update() do
      {:ok, updated_account} ->
        on_account_update(updated_account, changeset)
        {:ok, updated_account}

      {:error, reason} ->
        {:error, reason}
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
  end

  defp on_account_update(account, changeset) do
    :ok = Billing.on_account_update(account, changeset)
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

  def account_active?(%{disabled_at: nil}), do: true
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
      Account.Query.all()
      |> Account.Query.by_slug(slug_candidate)

    if queryable |> Safe.unscoped() |> Safe.exists?() do
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
end
