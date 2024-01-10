defmodule Domain.Accounts do
  alias Domain.{Repo, Validator}
  alias Domain.Auth
  alias Domain.Accounts.{Authorizer, Account}

  def list_accounts_by_ids(ids) do
    if Enum.all?(ids, &Validator.valid_uuid?/1) do
      Account.Query.by_id({:in, ids})
      |> Repo.list()
    else
      {:ok, []}
    end
  end

  def fetch_account_by_id(id, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_accounts_permission()),
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
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.view_accounts_permission()),
         true <- not is_nil(id_or_slug) do
      if Validator.valid_uuid?(id_or_slug) do
        Account.Query.by_id(id_or_slug)
      else
        Account.Query.by_slug(id_or_slug)
      end
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
    if Validator.valid_uuid?(id_or_slug) do
      Account.Query.by_id(id_or_slug)
    else
      Account.Query.by_slug(id_or_slug)
    end
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
end
