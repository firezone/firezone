defmodule Portal.GroupFixtures do
  @moduledoc """
  Test helpers for creating groups and related data.
  """

  import Portal.AccountFixtures
  import Portal.DirectoryFixtures

  @doc """
  Generate valid group attributes with sensible defaults.
  """
  def valid_group_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Group #{unique_num}",
      type: :static,
      entity_type: :group
    })
  end

  @doc """
  Generate a group with valid default attributes.

  The group will be created with an associated account unless one is provided.

  ## Examples

      group = group_fixture()
      group = group_fixture(name: "Engineering")
      group = group_fixture(account: account, type: :managed)

  """
  def group_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build group attrs without the account key
    group_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:directory)
      |> valid_group_attrs()

    changeset =
      %Portal.Group{}
      |> Ecto.Changeset.cast(group_attrs, [:name, :type, :entity_type, :idp_id, :last_synced_at])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Portal.Group.changeset()

    # Optionally associate with directory
    changeset =
      if directory = Map.get(attrs, :directory) do
        Ecto.Changeset.put_assoc(changeset, :directory, directory)
      else
        changeset
      end

    {:ok, group} = Portal.Repo.insert(changeset)
    group
  end

  @doc """
  Generate a managed group (synced from identity provider).
  """
  def managed_group_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    group_fixture(Map.put(attrs, :type, :managed))
  end

  @doc """
  Generate a static group (manually created).
  """
  def static_group_fixture(attrs \\ %{}) do
    Enum.into(attrs, %{})
    group_fixture(Map.put(attrs, :type, :static))
  end

  @doc """
  Generate an organizational unit group.
  """
  def org_unit_group_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:entity_type, :org_unit)
      |> Map.put(:type, :managed)

    group_fixture(attrs)
  end

  @doc """
  Generate a group with a specific IdP identifier.
  """
  def group_with_idp_id_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    unique_num = System.unique_integer([:positive, :monotonic])
    idp_id = "idp_#{unique_num}"

    group_fixture(Map.put(attrs, :idp_id, idp_id))
  end

  @doc """
  Generate a synced group (from identity provider).

  Creates a static group with a directory_id, simulating a group that was
  synced from an external directory service but is modifiable via PortalAPI.
  This is different from a managed group which cannot be fetched via the PortalAPI.

  ## Examples

      group = synced_group_fixture()
      group = synced_group_fixture(account: account)
      group = synced_group_fixture(name: "Sales Team")
      group = synced_group_fixture(directory: google_directory)

  """
  def synced_group_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Create a directory first if not provided (default to google)
    directory =
      if Map.has_key?(attrs, :directory) do
        Map.get(attrs, :directory)
      else
        # Get account to create directory with same account
        account = Map.get(attrs, :account) || account_fixture()

        # Create a google directory (this returns a generic Directory not a GoogleDirectory)
        google_directory_fixture(account: account)
      end

    attrs =
      attrs
      |> Map.put(:type, :static)
      |> Map.put(:directory, directory)
      |> Map.put_new(:last_synced_at, DateTime.utc_now())

    # Add idp_id if not provided
    attrs =
      if Map.has_key?(attrs, :idp_id) do
        attrs
      else
        unique_num = System.unique_integer([:positive, :monotonic])
        Map.put(attrs, :idp_id, "synced_#{unique_num}")
      end

    group_fixture(attrs)
  end
end
