defmodule Domain.Repo.Migrations.EncryptProviderAndIdentityState do
  use Ecto.Migration

  def change do
    execute(fn ->
      Domain.Auth.Provider.Query.not_deleted()
      |> Domain.Auth.Provider.Query.by_adapter(
        {:in,
         [
           :openid_connect,
           :google_workspace,
           :microsoft_entra,
           :okta
         ]}
      )
      |> repo().all()
      |> Enum.each(fn provider ->
        adapter_config =
          provider.adapter_config
          |> encrypt_key!(:client_secret)

        adapter_state =
          provider.adapter_state
          |> encrypt_key!(:access_token)
          |> encrypt_key!(:refresh_token)

        provider
        |> Ecto.Changeset.change(
          adapter_config: adapter_config,
          adapter_state: adapter_state
        )
        |> repo().update!()
      end)

      Domain.Auth.Identity.Query.all()
      |> repo().all()
      |> Enum.each(fn identity ->
        identity_provider_state =
          identity.provider_state
          |> encrypt_key!(:access_token)
          |> encrypt_key!(:refresh_token)

        identity
        |> Ecto.Changeset.change(provider_state: identity_provider_state)
        |> repo().update!()
      end)
    end)
  end

  defp encrypt_key!(map, key) do
    {_value, map} =
      Map.get_and_update(map, key, fn
        nil -> :pop
        value -> {value, Domain.Vault.encrypt!(value)}
      end)

    map
  end
end
