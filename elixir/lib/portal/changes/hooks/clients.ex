defmodule Portal.Changes.Hooks.Clients do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias __MODULE__.Database
  import Portal.SchemaHelpers

  @impl true
  def on_insert(_lsn, _data), do: :ok

  @impl true
  def on_update(lsn, old_data, data) do
    old_client = struct_from_params(Portal.Client, old_data)
    client = struct_from_params(Portal.Client, data)
    change = %Change{lsn: lsn, op: :update, old_struct: old_client, struct: client}

    # Unverifying a client
    # This is a special case - we need to delete associated policy_authorizations when unverifying a client since
    # it could affect connectivity if any policies are based on the verified status.
    if not is_nil(old_client.verified_at) and is_nil(client.verified_at) do
      Database.delete_policy_authorizations_for_client(client)
    end

    PubSub.Account.broadcast(client.account_id, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    client = struct_from_params(Portal.Client, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: client}

    PubSub.Account.broadcast(client.account_id, change)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Repo, PolicyAuthorization}

    def delete_policy_authorizations_for_client(%Portal.Client{} = client) do
      from(f in PolicyAuthorization, as: :policy_authorizations)
      |> where([policy_authorizations: f], f.account_id == ^client.account_id)
      |> where([policy_authorizations: f], f.client_id == ^client.id)
      # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
      |> Repo.delete_all()
    end
  end
end
