defmodule Domain.Accounts do
  alias Domain.{Repo, Validator, Config, PubSub}
  alias Domain.Auth
  alias Domain.Accounts.{Account, Features, Authorizer}

  def list_accounts_by_ids(ids) do
    if Enum.all?(ids, &Validator.valid_uuid?/1) do
      Account.Query.by_id({:in, ids})
      |> Repo.list()
    else
      {:ok, []}
    end
  end

  def fetch_account_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_account_permission()),
         true <- Validator.valid_uuid?(id) do
      Account.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_account_by_id_or_slug(id_or_slug, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_account_permission()),
         true <- not is_nil(id_or_slug) do
      id_or_slug
      |> Account.Query.by_id_or_slug()
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def fetch_account_by_id_or_slug(nil), do: {:error, :not_found}
  def fetch_account_by_id_or_slug(""), do: {:error, :not_found}

  def fetch_account_by_id_or_slug(id_or_slug) do
    id_or_slug
    |> Account.Query.by_id_or_slug()
    |> Repo.fetch()
  end

  def fetch_account_by_id(id) do
    if Validator.valid_uuid?(id) do
      Account.Query.by_id(id)
      |> Repo.fetch()
    else
      {:error, :not_found}
    end
  end

  def fetch_account_by_id!(id) do
    Account.Query.by_id(id)
    |> Repo.one!()
  end

  def create_account(attrs) do
    Account.Changeset.create(attrs)
    |> Repo.insert()
  end

  def change_account(%Account{} = account, attrs) do
    Account.Changeset.update(account, attrs)
  end

  def update_account(%Account{} = account, attrs, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_account_permission()) do
      Account.Query.by_id(account.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(
        with: fn account ->
          changeset = Account.Changeset.update_profile_and_config(account, attrs)
          {changeset, execute_after_commit: on_account_update_cb(changeset)}
        end
      )
    end
  end

  def update_account(%Account{} = account, attrs) do
    update_account_by_id(account.id, attrs)
  end

  def update_account_by_id(id, attrs) do
    Account.Query.all()
    |> Account.Query.by_id(id)
    |> Repo.fetch_and_update(
      with: fn account ->
        changeset = Account.Changeset.update(account, attrs)
        {changeset, execute_after_commit: on_account_update_cb(changeset)}
      end
    )
  end

  defp on_account_update_cb(changeset) do
    if Ecto.Changeset.changed?(changeset, :config) do
      &broadcast_config_update_to_account/1
    else
      fn _account -> :ok end
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

    if Account.Query.by_slug(slug_candidate) |> Repo.exists?() do
      generate_unique_slug()
    else
      slug_candidate
    end
  end

  ### PubSub

  defp account_topic(%Account{} = account), do: account_topic(account.id)
  defp account_topic(account_id), do: "accounts:#{account_id}"

  def subscribe_to_events_in_account(account_or_id) do
    PubSub.subscribe(account_topic(account_or_id))
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
