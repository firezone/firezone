defmodule Portal.Changes.Hooks.Accounts do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Billing, Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers
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
    account = struct_from_params(Portal.Account, old_data)
    Database.delete_policy_authorizations_for_account(account)
    Database.delete_client_tokens_for_account(account)

    on_delete(lsn, old_data)
  end

  def on_update(lsn, old_data, data) do
    old_account = struct_from_params(Portal.Account, old_data)
    account = struct_from_params(Portal.Account, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_account, struct: account}

    # Start async task for billing update if name or slug changed
    if old_data["name"] != data["name"] or old_data["slug"] != data["slug"] do
      Task.start(fn ->
        :ok = Billing.on_account_name_or_slug_changed(account)
      end)
    end

    PubSub.Changes.broadcast(account.id, change)
  end

  @impl true

  def on_delete(lsn, old_data) do
    account = struct_from_params(Portal.Account, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: account}

    PubSub.Changes.broadcast(account.id, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ClientToken
    alias Portal.PolicyAuthorization
    alias Portal.Safe

    def delete_policy_authorizations_for_account(%Portal.Account{} = account) do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: pa], pa.account_id == ^account.id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def delete_client_tokens_for_account(%Portal.Account{} = account) do
      from(ct in ClientToken, as: :client_tokens)
      |> where([client_tokens: ct], ct.account_id == ^account.id)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end
  end
end
