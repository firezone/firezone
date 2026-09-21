defmodule Portal.IdentityFixtures do
  @moduledoc """
  Test helpers for creating external identities and related data.
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.DirectoryFixtures

  @doc """
  Generate valid external identity attributes with sensible defaults.
  """
  def valid_identity_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])
    email = "user#{unique_num}@example.com"

    Enum.into(attrs, %{
      issuer: "https://auth#{unique_num}.example.com",
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
      %Portal.ExternalIdentity{}
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
        :firezone_avatar_url
      ])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Ecto.Changeset.put_assoc(:actor, actor)
      |> Portal.ExternalIdentity.changeset()

    # Optionally associate with directory
    changeset =
      if directory = Map.get(attrs, :directory) do
        Ecto.Changeset.put_assoc(changeset, :directory, directory)
      else
        changeset
      end

    {:ok, identity} = Portal.Repo.insert(changeset)

    # If synced_at was provided, create a sync state record
    if synced_at = Map.get(attrs, :synced_at) do
      %Portal.ExternalIdentitySyncState{
        external_identity_id: identity.id,
        account_id: account.id,
        synced_at: synced_at
      }
      |> Portal.Repo.insert!(
        on_conflict: {:replace, [:synced_at]},
        conflict_target: [:account_id, :external_identity_id]
      )
    end

    identity
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
      |> Map.put_new(:synced_at, DateTime.utc_now())
      |> Map.put_new(:account, account)
      |> Map.put_new(:directory, directory)

    identity_fixture(attrs)
  end

  defp account_and_directory(%{directory: directory} = attrs) do
    directory_account = Portal.Repo.get_by!(Portal.Account, id: directory.account_id)
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
