defmodule Domain.Resource do
  use Domain, :schema

  @type filter :: %{
          protocol: :tcp | :udp | :icmp,
          ports: [Domain.Types.Int4Range.t()]
        }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          address: String.t(),
          address_description: String.t() | nil,
          name: String.t(),
          type: :cidr | :ip | :dns | :internet,
          ip_stack: :ipv4_only | :ipv6_only | :dual,
          filters: [filter()],
          account_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "resources" do
    field :address, :string
    field :address_description, :string
    field :name, :string

    field :type, Ecto.Enum, values: [:cidr, :ip, :dns, :internet]
    field :ip_stack, Ecto.Enum, values: [:ipv4_only, :ipv6_only, :dual]

    embeds_many :filters, Filter, on_replace: :delete, primary_key: false do
      field :protocol, Ecto.Enum, values: [tcp: 6, udp: 17, icmp: 1]
      field :ports, {:array, Domain.Types.Int4Range}, default: []
    end

    belongs_to :account, Domain.Accounts.Account
    has_many :connections, Domain.Resources.Connection, on_replace: :delete
    has_many :gateway_groups, through: [:connections, :gateway_group]

    has_many :policies, Domain.Policies.Policy
    has_many :actor_groups, through: [:policies, :actor_group]

    # Warning: do not do Repo.preload/2 for this field, it will not work intentionally,
    # because the actual preload query should also use joins and process policy conditions
    has_many :authorized_by_policies, Domain.Policies.Policy, where: [id: {:fragment, "FALSE"}]

    timestamps()
  end

  def changeset(changeset) do
    import Domain.Repo.Changeset
    import Ecto.Changeset

    fields = ~w[address address_description name type ip_stack]a
    
    changeset
    |> trim_change(fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:address_description, min: 1, max: 512)
    |> maybe_put_default_ip_stack()
    |> check_constraint(:ip_stack,
      name: :resources_ip_stack_not_null,
      message:
        "IP stack must be one of 'dual', 'ipv4_only', 'ipv6_only' for DNS resources or NULL for others"
    )
    |> cast_embed(:filters, with: &filter_changeset/2)
    |> unique_constraint(:name,
      name: :resources_account_id_name_index,
      message: "resource with this name already exists"
    )
  end
  
  defp maybe_put_default_ip_stack(changeset) do
    import Ecto.Changeset
    
    case fetch_field(changeset, :type) do
      {_data_or_changes, :dns} ->
        case fetch_field(changeset, :ip_stack) do
          {_data_or_changes, nil} ->
            put_change(changeset, :ip_stack, :dual)

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp filter_changeset(struct, attrs) do
    import Ecto.Changeset
    
    struct
    |> cast(attrs, [:protocol, :ports])
    |> validate_required([:protocol])
  end

  # Utility functions moved from Domain.Resources

  @doc """
    This does two things:
    1. Filters out resources that are not compatible with the given client or gateway version.
    2. Converts DNS resource addresses back to the pre-1.2.0 format if the client or gateway version is < 1.2.0.
  """
  def adapt_resource_for_version(resource, client_or_gateway_version) do
    cond do
      # internet resources require client and gateway >= 1.3.0
      resource.type == :internet and Version.match?(client_or_gateway_version, "< 1.3.0") ->
        nil

      # non-internet resource, pass as-is
      Version.match?(client_or_gateway_version, ">= 1.2.0") ->
        resource

      # we need convert dns resource addresses back to pre-1.2.0 format
      true ->
        resource.address
        |> String.codepoints()
        |> map_resource_address()
        |> case do
          {:cont, address} -> %{resource | address: address}
          :drop -> nil
        end
    end
  end

  defp map_resource_address(address, acc \\ "")

  defp map_resource_address(["*", "*" | rest], ""),
    do: map_resource_address(rest, "*")

  defp map_resource_address(["*", "*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["*" | rest], ""),
    do: map_resource_address(rest, "?")

  defp map_resource_address(["*" | _rest], _acc),
    do: :drop

  defp map_resource_address(["?" | _rest], _acc),
    do: :drop

  defp map_resource_address([char | rest], acc),
    do: map_resource_address(rest, acc <> char)

  defp map_resource_address([], acc),
    do: {:cont, acc}
end