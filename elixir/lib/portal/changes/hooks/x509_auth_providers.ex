defmodule Portal.Changes.Hooks.X509AuthProviders do
  @behaviour Portal.Changes.Hooks
  alias Portal.{Changes.Change, PubSub}
  alias Portal.X509.AuthProvider
  import Portal.SchemaHelpers

  @impl true
  def on_insert(lsn, data) do
    auth_provider = struct_from_params(AuthProvider, data)
    change = %Change{lsn: lsn, op: :insert, struct: auth_provider}

    PubSub.Changes.broadcast(auth_provider.account_id, :x509_auth_providers, change)
  end

  @impl true
  def on_update(lsn, old_data, data) do
    old_auth_provider = struct_from_params(AuthProvider, old_data)
    auth_provider = struct_from_params(AuthProvider, data)

    change = %Change{
      lsn: lsn,
      op: :update,
      old_struct: old_auth_provider,
      struct: auth_provider
    }

    PubSub.Changes.broadcast(auth_provider.account_id, :x509_auth_providers, change)
  end

  @impl true
  def on_delete(lsn, old_data) do
    auth_provider = struct_from_params(AuthProvider, old_data)
    change = %Change{lsn: lsn, op: :delete, old_struct: auth_provider}

    PubSub.Changes.broadcast(auth_provider.account_id, :x509_auth_providers, change)
  end
end
