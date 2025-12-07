defmodule Domain.TokenFixtures do
  @moduledoc """
  Test helpers for creating tokens and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.SiteFixtures

  @doc """
  Generate valid token attributes with sensible defaults.
  """
  def valid_token_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      type: :browser,
      name: "Token #{unique_num}",
      secret_salt: generate_salt(),
      secret_hash: generate_hash(),
      remaining_attempts: 3,
      # Default expiration 30 days from now
      expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
    })
  end

  @doc """
  Generate a token with valid default attributes.

  The token will be created with an associated account and actor/site
  depending on the token type.

  ## Examples

      token = token_fixture()
      token = token_fixture(type: :client)
      token = token_fixture(actor: actor, type: :browser)

  """
  def token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build token attrs
    token_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:actor)
      |> Map.delete(:site)
      |> Map.delete(:auth_provider)
      |> valid_token_attrs()

    changeset =
      %Domain.Token{}
      |> Ecto.Changeset.cast(token_attrs, [
        :type,
        :name,
        :secret_salt,
        :secret_hash,
        :remaining_attempts,
        :last_seen_user_agent,
        :last_seen_remote_ip,
        :last_seen_remote_ip_location_region,
        :last_seen_remote_ip_location_city,
        :last_seen_remote_ip_location_lat,
        :last_seen_remote_ip_location_lon,
        :last_seen_at,
        :expires_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Token.changeset()

    # Associate with actor for browser/client/api_client tokens
    changeset =
      if Map.get(token_attrs, :type) in [:browser, :client, :api_client] do
        actor = Map.get(attrs, :actor) || actor_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :actor, actor)
      else
        changeset
      end

    # Associate with site for site tokens
    changeset =
      if Map.get(token_attrs, :type) == :site do
        site = Map.get(attrs, :site) || site_fixture(account: account)
        Ecto.Changeset.put_assoc(changeset, :site, site)
      else
        changeset
      end

    # Optionally associate with auth_provider
    changeset =
      if auth_provider = Map.get(attrs, :auth_provider) do
        Ecto.Changeset.put_assoc(changeset, :auth_provider, auth_provider)
      else
        changeset
      end

    {:ok, token} = Domain.Repo.insert(changeset)
    token
  end

  @doc """
  Generate a browser token.
  """
  def browser_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :browser))
  end

  @doc """
  Generate a client token.
  """
  def client_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :client))
  end

  @doc """
  Generate an API client token.
  """
  def api_client_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :api_client))
  end

  @doc """
  Generate a relay token.
  """
  def relay_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :relay))
  end

  @doc """
  Generate a site token (for gateway).
  """
  def site_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :site))
  end

  @doc """
  Generate an email token.
  """
  def email_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :type, :email))
  end

  @doc """
  Generate an expired token.
  """
  def expired_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :expires_at, DateTime.add(DateTime.utc_now(), -3600, :second)))
  end

  @doc """
  Generate a token with last seen information.
  """
  def active_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    attrs =
      attrs
      |> Map.put_new(:last_seen_at, DateTime.utc_now())
      |> Map.put_new(:last_seen_user_agent, "Mozilla/5.0")
      |> Map.put_new(:last_seen_remote_ip, {100, 64, 0, 1})

    token_fixture(attrs)
  end

  @doc """
  Generate a token with no remaining attempts.
  """
  def exhausted_token_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    token_fixture(Map.put(attrs, :remaining_attempts, 0))
  end

  # Private helpers

  defp generate_salt do
    :crypto.strong_rand_bytes(16)
    |> Base.encode64()
  end

  defp generate_hash do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end
end
