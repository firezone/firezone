defmodule Portal.ResourceFixtures do
  @moduledoc """
  Test helpers for creating resources and related data.
  """

  import Portal.AccountFixtures

  @doc """
  Generate valid resource attributes with sensible defaults.
  """
  def valid_resource_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Resource #{unique_num}",
      address: "10.0.#{rem(unique_num, 255)}.#{rem(unique_num, 255)}",
      type: :cidr
    })
  end

  @doc """
  Generate a resource with valid default attributes.

  The resource will be created with an associated account unless one is provided.

  ## Examples

      resource = resource_fixture()
      resource = resource_fixture(name: "Internal Network")
      resource = resource_fixture(account: account, type: :dns)

  """
  def resource_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    # Build resource attrs without the account and site keys
    resource_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:site)
      |> valid_resource_attrs()

    changeset =
      %Portal.Resource{}
      |> Ecto.Changeset.cast(resource_attrs, [
        :name,
        :address,
        :address_description,
        :type,
        :ip_stack
      ])
      |> Ecto.Changeset.cast_embed(:filters, with: &filter_changeset/2)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Portal.Resource.changeset()

    # Optionally associate with site
    changeset =
      if site = Map.get(attrs, :site) do
        Ecto.Changeset.put_assoc(changeset, :site, site)
      else
        changeset
      end

    {:ok, resource} = Portal.Repo.insert(changeset)
    resource
  end

  @doc """
  Generate a DNS resource.
  """
  def dns_resource_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :dns)
      |> Map.put_new(:address, "app#{unique_num}.example.com")
      |> Map.put_new(:ip_stack, :dual)

    resource_fixture(attrs)
  end

  @doc """
  Generate a CIDR resource.
  """
  def cidr_resource_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :cidr)
      |> Map.put_new(:address, "10.#{rem(unique_num, 255)}.0.0/16")

    resource_fixture(attrs)
  end

  @doc """
  Generate an IP resource.
  """
  def ip_resource_fixture(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :ip)
      |> Map.put_new(:address, "10.0.#{rem(unique_num, 255)}.#{rem(unique_num, 255)}")

    resource_fixture(attrs)
  end

  @doc """
  Generate an internet resource.
  Internet resources don't have an address (it's set to nil by the changeset).
  """
  def internet_resource_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Get or create account
    account = Map.get(attrs, :account) || account_fixture()

    unique_num = System.unique_integer([:positive, :monotonic])

    resource_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:site)
      |> Map.put(:type, :internet)
      |> Map.put_new(:name, "Internet Resource #{unique_num}")
      |> Map.delete(:address)

    changeset =
      %Portal.Resource{}
      |> Ecto.Changeset.cast(resource_attrs, [:name, :type])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Portal.Resource.changeset()

    changeset =
      if site = Map.get(attrs, :site) do
        Ecto.Changeset.put_assoc(changeset, :site, site)
      else
        changeset
      end

    {:ok, resource} = Portal.Repo.insert(changeset)
    resource
  end

  @doc """
  Generate a resource with filters.
  """
  def resource_with_filters_fixture(attrs \\ %{}) do
    filters =
      Map.get(attrs, :filters, [
        %{protocol: :tcp, ports: ["80", "443"]},
        %{protocol: :udp, ports: ["53"]}
      ])

    attrs = Map.put(attrs, :filters, filters)
    resource_fixture(attrs)
  end

  @doc """
  Generate a resource with a specific protocol filter.
  """
  def tcp_resource_fixture(attrs \\ %{}) do
    ports = Map.get(attrs, :ports, ["80", "443"])

    attrs =
      attrs
      |> Map.put(:filters, [%{protocol: :tcp, ports: ports}])

    resource_fixture(attrs)
  end

  @doc """
  Generate a resource with UDP filter.
  """
  def udp_resource_fixture(attrs \\ %{}) do
    ports = Map.get(attrs, :ports, ["53"])

    attrs =
      attrs
      |> Map.put(:filters, [%{protocol: :udp, ports: ports}])

    resource_fixture(attrs)
  end

  @doc """
  Update a resource with the given attributes.
  """
  def update_resource(resource, attrs) do
    attrs = Enum.into(attrs, %{})

    resource
    |> Ecto.Changeset.cast(attrs, [:name, :address, :address_description, :site_id])
    |> Portal.Repo.update!()
  end

  # Private helper for casting filter embeds
  defp filter_changeset(filter, attrs) do
    filter
    |> Ecto.Changeset.cast(attrs, [:protocol, :ports])
  end
end
