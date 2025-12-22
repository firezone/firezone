defmodule Domain.Changes.Hooks.Accounts do
  @behaviour Domain.Changes.Hooks
  alias Domain.{Billing, Changes.Change, PubSub}
  alias __MODULE__.DB
  import Domain.SchemaHelpers
  require Logger

  @impl true
  def on_insert(_lsn, _data), do: :ok

  # Account slug changed - disconnect gateways for updated init

  @impl true

  # Account disabled - process as a delete
  def on_update(
        lsn,
        %{"disabled_at" => nil} = old_data,
        %{"disabled_at" => disabled_at}
      )
      when not is_nil(disabled_at) do
    account = struct_from_params(Domain.Account, old_data)
    DB.delete_policy_authorizations_for_account(account)
    DB.delete_client_tokens_for_account(account)

    on_delete(lsn, old_data)
  end

  def on_update(lsn, old_data, data) do
    old_account = struct_from_params(Domain.Account, old_data)
    account = struct_from_params(Domain.Account, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_account, struct: account}

    # Start async task for billing update if name or slug changed
    if old_data["name"] != data["name"] or old_data["slug"] != data["slug"] do
      Task.start(fn ->
        :ok = Billing.on_account_name_or_slug_changed(account)
      end)
    end

    PubSub.Account.broadcast(account.id, change)
  end

  @impl true

  def on_delete(lsn, old_data) do
    account = struct_from_params(Domain.Account, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: account}

    PubSub.Account.broadcast(account.id, change)
  end

  defmodule DB do
    import Ecto.Query
    alias Domain.ClientToken
    alias Domain.PolicyAuthorization
    alias Domain.Safe

    def delete_policy_authorizations_for_account(%Domain.Account{} = account) do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.account_id == ^account.id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_client_tokens_for_account(%Domain.Account{} = account) do
      from(ct in ClientToken, as: :client_tokens)
      |> where([client_tokens: ct], ct.account_id == ^account.id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
