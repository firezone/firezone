defmodule Web.ResourceForm do
  use Domain, :schema
  use Domain, :changeset

  @default_filters [
    %{"enabled" => false, "protocol" => "all", "ports" => "", "display_name" => "Permit All"},
    %{"enabled" => false, "protocol" => "icmp", "ports" => "", "display_name" => "ICMP"},
    %{"enabled" => false, "protocol" => "tcp", "ports" => "", "display_name" => "TCP"},
    %{"enabled" => false, "protocol" => "udp", "ports" => "", "display_name" => "UDP"}
  ]

  @default_attrs %{
    "address" => "",
    "name" => "",
    "filters" => @default_filters,
    "connections" => []
  }

  @display_names %{"all" => "Permit All", "icmp" => "ICMP", "tcp" => "TCP", "udp" => "UDP"}

  embedded_schema do
    field(:address, :string)
    field(:name, :string)

    embeds_many :filters, Filter, on_replace: :delete do
      field(:enabled, :boolean)
      field(:protocol, :string)
      field(:ports, :string, default: "")
    end

    embeds_many :connections, Connection, on_replace: :delete do
      field(:enabled, :boolean)
      field(:gateway_group_id, :string)
      field(:gateway_group_name, :string)
    end
  end

  def new_resource_form(attrs) do
    %Web.ResourceForm{}
    |> cast(attrs, [:address, :name])
    |> validate_required([:address, :name])
    |> cast_embed(:filters, with: &cast_filter/2)
    |> cast_embed(:connections, with: &cast_connection/2)
  end

  defp cast_filter(filter, attrs) do
    filter
    |> cast(attrs, [:enabled, :protocol, :ports])
    |> validate_required([:enabled, :protocol])
    |> validate_inclusion(:protocol, ["all", "icmp", "tcp", "udp"])
    |> validate_format(:ports, ~r/^\d+(?:-\d+)?(?:,\s\d+(?:-\d+)?)*$/u,
      message: "must be a comma-separated list of port ranges"
    )
  end

  defp cast_connection(connection, attrs) do
    connection
    |> cast(attrs, [:enabled, :gateway_group_id])
    |> validate_required([:enabled, :gateway_group_id])
  end

  def ports_to_str(ports) do
    Enum.join(ports, ", ")
  end

  def ports_to_list(ports) do
    # Remove all whitespace first
    Regex.replace(~r/\s/u, ports, "")
    |> String.split(",")
  end

  def validate(attrs) do
    new_resource_form(attrs)
    |> apply_action(:create)
  end

  # TODO: Refactor this function
  def from_domain(schema, gateway_groups) do
    filters =
      default_filters()
      |> Enum.map(fn filter ->
        domain_filter =
          Enum.find(schema.filters, fn f ->
            Atom.to_string(f.protocol) == filter["protocol"]
          end)

        if domain_filter do
          %{filter | "enabled" => true, "ports" => ports_to_str(domain_filter.ports)}
        else
          filter
        end
      end)

    connections =
      Enum.map(gateway_groups, fn group ->
        %{
          "enabled" => Enum.any?(schema.connections, fn c -> c.gateway_group_id == group.id end),
          "gateway_group_id" => group.id,
          "gateway_group_name" => group.name_prefix
        }
      end)

    new_resource_form(%{
      "address" => schema.address,
      "name" => schema.name,
      "filters" => filters,
      "connections" => connections
    })
  end

  def to_domain_attrs(schema) do
    %{
      "address" => schema.address,
      "name" => schema.name,
      "filters" => filters_to_attrs(schema.filters),
      "connections" => connections_to_attrs(schema.connections)
    }
  end

  def filters_to_attrs(filters) do
    Enum.map(filters, fn filter ->
      %{
        enabled: filter.enabled,
        protocol: filter.protocol,
        ports: ports_to_list(filter.ports)
      }
    end)
    |> Enum.filter(fn filter -> filter.enabled end)
  end

  def connections_to_attrs(connections) do
    Enum.map(connections, fn connection ->
      %{enabled: connection.enabled, gateway_group_id: connection.gateway_group_id}
    end)
    |> Enum.filter(fn connection -> connection.enabled end)
  end

  def default_filters() do
    @default_filters
  end

  def default_attrs() do
    @default_attrs
  end

  def map_errors(attrs, domain_changeset) do
    web_cs = new_resource_form(attrs)
    %Ecto.Changeset{web_cs | errors: web_cs.errors ++ domain_changeset.errors}
  end

  def display_name(protocol) do
    @display_names[protocol]
  end
end
