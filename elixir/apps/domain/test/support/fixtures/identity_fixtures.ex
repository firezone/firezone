defmodule Domain.IdentityFixtures do
  @moduledoc """
  Test helpers for creating external identities and related data.
  """

  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.DirectoryFixtures

  @doc """
  Generate valid external identity attributes with sensible defaults.
  """
  def valid_identity_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])
    email = "user#{unique_num}@example.com"

    Enum.into(attrs, %{
      issuer: "https://auth.example.com",
      idp_id: email,
      email: email,
      name: "Test User #{unique_num}",
      given_name: "Test",
      family_name: "User"
    })
  end

  @doc """
  Generate an external identity with valid default attributes.

  The identity will be created with an associated account and actor unless they are provided.

  ## Examples

      identity = identity_fixture()
      identity = identity_fixture(email: "alice@example.com")
      identity = identity_fixture(actor: actor)

  """
  def identity_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # attrs =
    #  attrs
    #  |> Map.put_new(:idp_id, Map.get(attrs, :provider_identifier))
    #  |> Map.delete(:provider_identifier)

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Get or create actor
    actor = Map.get(attrs, :actor) || actor_fixture(account: account)

    # Build identity attrs
    identity_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:actor)
      |> Map.delete(:directory)
      |> valid_identity_attrs()

    changeset =
      %Domain.ExternalIdentity{}
      |> Ecto.Changeset.cast(identity_attrs, [
        :issuer,
        :idp_id,
        :email,
        :name,
        :given_name,
        :family_name,
        :middle_name,
        :nickname,
        :preferred_username,
        :profile,
        :picture,
        :firezone_avatar_url,
        :last_synced_at
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Domain.ExternalIdentity.changeset()

    # Optionally associate with directory
    changeset =
      if directory = Map.get(attrs, :directory) do
        Ecto.Changeset.put_assoc(changeset, :directory, directory)
      else
        changeset
      end

    {:ok, identity} = Domain.Repo.insert(changeset)
    identity
  end

  @doc """
  Generate an identity with full profile information.
  """
  def identity_with_full_profile_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:middle_name, "Middle")
      |> Map.put_new(:nickname, "nickname#{unique_num}")
      |> Map.put_new(:preferred_username, "preferred#{unique_num}")
      |> Map.put_new(:profile, "https://example.com/profile/user#{unique_num}")
      |> Map.put_new(:picture, "https://example.com/avatar/user#{unique_num}.jpg")

    identity_fixture(attrs)
  end

  @doc """
  Generate a synced identity (from directory sync).
  """
  def synced_identity_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])

    {account, directory} = account_and_directory(attrs)

    attrs =
      attrs
      |> Map.drop([:account, :directory])
      |> Map.put_new(:name, "Test User #{unique_num}")
      |> Map.put_new(:given_name, "Test")
      |> Map.put_new(:family_name, "User")
      |> Map.put_new(:middle_name, "Middle")
      |> Map.put_new(:nickname, "nickname_#{unique_num}")
      |> Map.put_new(:preferred_username, "preferred_#{unique_num}")
      |> Map.put_new(:profile, "https://example.com/profile/user_#{unique_num}")
      |> Map.put_new(:picture, "https://example.com/avatar/user_#{unique_num}.jpg")
      |> Map.put_new(:last_synced_at, DateTime.utc_now())
      |> Map.put_new(:account, account)
      |> Map.put_new(:directory, directory)

    identity_fixture(attrs)
  end

  @doc """
  Generate an identity with a Firezone-hosted avatar.
  """
  def identity_with_avatar_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(
        :firezone_avatar_url,
        "https://storage.example.com/avatars/#{unique_num}.jpg"
      )

    identity_fixture(attrs)
  end

  @doc """
  Generate an identity for a specific provider.
  """
  def identity_for_provider_fixture(issuer, attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:issuer, issuer)
      |> Map.put_new(:idp_id, "#{issuer}_user_#{unique_num}")

    identity_fixture(attrs)
  end

  @doc """
  Create multiple identities for the same actor (multi-IdP scenario).
  """
  def actor_identities_fixture(actor, count \\ 3, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = actor.account || Domain.Repo.preload(actor, :account).account

    for i <- 1..count do
      unique_num = System.unique_integer([:positive, :monotonic])

      identity_fixture(
        Map.merge(
          %{
            actor: actor,
            account: account,
            issuer: "https://auth#{i}.example.com",
            idp_id: "idp_user_#{unique_num}"
          },
          attrs
        )
      )
    end
  end

  defp account_and_directory(%{directory: directory} = attrs) do
    directory_account = Domain.Repo.get_by!(Domain.Account, id: directory.account_id)
    account = Map.get(attrs, :account, directory_account)
    account = if account.id == directory_account.id, do: account, else: directory_account
    {account, directory}
  end

  defp account_and_directory(attrs) do
    account = Map.get(attrs, :account) || account_fixture()
    directory = synced_google_directory_fixture(account: account)
    {account, directory}
  end
end
