defmodule Domain.APITokenFixtures do
  @moduledoc """
  Test helpers for building API tokens.
  """

  import Ecto.Changeset
  import Domain.AccountFixtures
  import Domain.ActorFixtures

  def valid_api_token_attrs do
    %{
      name: "Test API Token",
      secret_fragment: generate_secret_fragment(),
      secret_salt: generate_salt(),
      expires_at: DateTime.utc_now() |> DateTime.add(30, :day)
    }
  end

  @doc """
  Build an API token with sensible defaults.
  """
  def api_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, valid_api_token_attrs())

    account = Map.get_lazy(attrs, :account, &account_fixture/0)

    actor =
      Map.get_lazy(attrs, :actor, fn -> actor_fixture(account: account, type: :api_client) end)

    attrs =
      attrs
      |> Map.put_new_lazy(:secret_hash, fn ->
        compute_secret_hash(attrs.secret_fragment, attrs.secret_salt)
      end)

    %Domain.APIToken{}
    |> change(attrs)
    |> put_assoc(:account, account)
    |> put_assoc(:actor, actor)
    |> Domain.Repo.insert!()
  end

  @doc """
  Encode an API token for use in authentication.
  """
  def encode_api_token(token) do
    config = Domain.Config.fetch_env!(:domain, Domain.Tokens)
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt) <> "api_client"
    body = {token.account_id, token.id, token.secret_fragment}

    "." <> Plug.Crypto.sign(key_base, salt, body)
  end

  defp generate_salt do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  defp generate_secret_fragment do
    :crypto.strong_rand_bytes(32)
    |> Base.hex_encode32(case: :upper, padding: true)
  end

  defp compute_secret_hash(fragment, salt) do
    # Nonce is always "" for API tokens
    :crypto.hash(:sha3_256, "" <> fragment <> salt)
    |> Base.encode16(case: :lower)
  end
end
