defmodule Domain.ResourceFixtures do
  @moduledoc """
  Test helpers for creating resources and related data.
  """

  import Domain.AccountFixtures

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
      %Domain.Resource{}
      |> Ecto.Changeset.cast(resource_attrs, [
        :name,
        :address,
        :address_description,
        :type,
        :ip_stack
      ])
      |> Ecto.Changeset.cast_embed(:filters)
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Domain.Resource.changeset()

    # Optionally associate with site
    changeset =
      if site = Map.get(attrs, :site) do
        Ecto.Changeset.put_assoc(changeset, :site, site)
      else
        changeset
      end

    {:ok, resource} = Domain.Repo.insert(changeset)
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
  """
  def internet_resource_fixture(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put(:type, :internet)
      |> Map.put(:address, "0.0.0.0/0")

    resource_fixture(attrs)
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
end
