defmodule Domain.Actors do
  alias Domain.Actors.Membership
  alias Domain.{Repo, Safe}
  alias Domain.{Accounts, Auth, Billing}
  alias Domain.Actors.{Actor, Group}
  require Ecto.Query
  require Logger

  # Groups

  def fetch_group_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Group.Query.all()
        |> Group.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_membership_by_actor_id_and_group_id(actor_id, group_id) do
    Membership.Query.all()
    |> Membership.Query.by_actor_id(actor_id)
    |> Membership.Query.by_group_id(group_id)
    |> Repo.fetch(Membership.Query)
  end

  def all_groups!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Group.Query.all()
    |> Safe.scoped(subject)
    |> Safe.all()
    |> case do
      {:error, :unauthorized} -> []
      groups -> Safe.preload(groups, preload)
    end
  end

  def all_editable_groups!(%Auth.Subject{} = subject, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Group.Query.all()
    |> Group.Query.editable()
    |> Safe.scoped(subject)
    |> Safe.all()
    |> case do
      {:error, :unauthorized} -> []
      groups -> Safe.preload(groups, preload)
    end
  end

  def all_memberships_for_actor_id!(actor_id) do
    Membership.Query.all()
    |> Membership.Query.by_actor_id(actor_id)
    |> Safe.unscoped()
    |> Safe.all()
  end

  def new_group(attrs \\ %{}) do
    change_group(%Group{directory_id: nil}, attrs)
  end

  def create_managed_group(%Accounts.Account{} = account, attrs) do
    Group.Changeset.create(account, attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def create_group(attrs, %Auth.Subject{} = subject) do
    Group.Changeset.create(subject.account, attrs, subject)
    |> Safe.scoped(subject)
    |> Safe.insert()
  end

  def change_group(group, attrs \\ %{})

  def change_group(%Group{type: :managed}, _attrs) do
    raise ArgumentError, "can't change managed groups"
  end

  def change_group(%Group{directory_id: nil} = group, attrs) do
    Group.Changeset.update(group, attrs)
  end

  def change_group(%Group{}, _attrs) do
    raise ArgumentError, "can't change synced groups"
  end

  def update_group(%Group{type: :managed}, _attrs, %Auth.Subject{}) do
    {:error, :managed_group}
  end

  def update_group(%Group{directory_id: nil} = group, attrs, %Auth.Subject{} = subject) do
    group
    |> Safe.preload(:memberships)
    |> Group.Changeset.update(attrs)
    |> Safe.scoped(subject)
    |> Safe.update()
  end

  def update_group(%Group{}, _attrs, %Auth.Subject{}) do
    {:error, :synced_group}
  end

  def delete_group(%Group{} = group, %Auth.Subject{} = subject) do
    Safe.scoped(group, subject)
    |> Safe.delete()
  end

  # Actors

  def count_users_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type({:in, [:account_admin_user, :account_user]})
    |> Safe.unscoped()
    |> Safe.aggregate(:count)
  end

  def count_account_admin_users_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:account_admin_user)
    |> Safe.unscoped()
    |> Safe.aggregate(:count)
  end

  def count_service_accounts_for_account(%Accounts.Account{} = account) do
    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:service_account)
    |> Safe.unscoped()
    |> Safe.aggregate(:count)
  end

  def fetch_actor_by_account_and_email(%Accounts.Account{} = account, email) do
    Actor.Query.all()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_email(email)
    |> Repo.fetch(Actor.Query)
  end

  def fetch_actor_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Actor.Query.all()
        |> Actor.Query.by_id(id)
        |> Safe.scoped(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def fetch_active_actor_by_id(id) do
    if Repo.valid_uuid?(id) do
      Actor.Query.not_disabled()
      |> Actor.Query.by_id(id)
      |> Repo.fetch(Actor.Query, [])
    else
      {:error, :not_found}
    end
  end

  def all_actor_group_ids!(%Actor{} = actor) do
    Membership.Query.by_actor_id(actor.id)
    |> Membership.Query.select_distinct_group_ids()
    |> Safe.unscoped()
    |> Safe.all()
  end

  def all_admins_for_account!(%Accounts.Account{} = account, opts \\ []) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    Actor.Query.not_disabled()
    |> Actor.Query.by_account_id(account.id)
    |> Actor.Query.by_type(:account_admin_user)
    |> Safe.unscoped()
    |> Safe.all()
    |> Safe.preload(preload)
  end

  def list_actors(%Auth.Subject{} = subject, opts \\ []) do
    Actor.Query.all()
    |> Safe.scoped(subject)
    |> Safe.list(Actor.Query, opts)
  end

  def new_actor(attrs \\ %{memberships: []}) do
    Actor.Changeset.create(attrs)
  end

  def create_actor(%Accounts.Account{} = account, attrs) do
    Actor.Changeset.create(account.id, attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def create_actor(%Accounts.Account{} = account, attrs, %Auth.Subject{} = subject) do
    with changeset = Actor.Changeset.create(account.id, attrs, subject),
         :ok <- ensure_billing_limits_not_exceeded(account, changeset) do
      Safe.scoped(changeset, subject)
      |> Safe.insert()
    end
  end

  defp ensure_billing_limits_not_exceeded(account, %{valid?: true} = changeset) do
    case Ecto.Changeset.fetch_field!(changeset, :type) do
      :service_account ->
        if Billing.can_create_service_accounts?(account) do
          :ok
        else
          {:error, :service_accounts_limit_reached}
        end

      :account_admin_user ->
        if Billing.can_create_users?(account) and Billing.can_create_admin_users?(account) do
          :ok
        else
          {:error, :seats_limit_reached}
        end

      :account_user ->
        if Billing.can_create_users?(account) do
          :ok
        else
          {:error, :seats_limit_reached}
        end

      _other ->
        :ok
    end
  end

  defp ensure_billing_limits_not_exceeded(_account, _changeset) do
    # we return :ok because we want Repo.insert() call to still put action and
    # rest of possible metadata if there are validation errors
    :ok
  end
end
