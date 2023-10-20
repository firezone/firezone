defmodule Domain.Config.Configuration.ClientsUpstreamDNS do
  @moduledoc """
  Embedded Schema for Clients Upstream DNS
  """
  use Domain, :schema
  import Domain.Validator
  import Ecto.Changeset
  alias Domain.Types.IPPort

  @primary_key false
  embedded_schema do
    field :protocol, Ecto.Enum, values: [:ip_port, :dns_over_tls, :dns_over_http]
    field :address, :string
  end

  def changeset(dns_config \\ %__MODULE__{}, attrs) do
    dns_config
    |> cast(attrs, [:protocol, :address])
    |> validate_required([:protocol, :address])
    |> trim_change(:address)
    |> validate_inclusion(:protocol, supported_protocols(),
      message: "this type of DNS provider is not supported yet"
    )
    |> validate_address()
  end

  def supported_protocols do
    ~w[ip_port]a
  end

  def validate_address(changeset) do
    if has_errors?(changeset, :protocol) do
      changeset
    else
      case fetch_field(changeset, :protocol) do
        {_, :ip_port} -> validate_ip_port(changeset)
        {_, _} -> changeset
      end
    end
  end

  def validate_ip_port(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      case IPPort.cast(address) do
        {:ok, _ip} -> []
        _ -> [address: "must be a valid IP address"]
      end
    end)
  end

  def normalize_dns_address(%__MODULE__{protocol: :ip_port, address: address}) do
    case IPPort.cast(address) do
      {:ok, ip} -> IPPort.put_default_port(ip, IPPort.default_dns_port()) |> to_string()
      _ -> address
    end
  end

  def normalize_dns_address(%__MODULE__{protocol: _, address: address}) do
    address
  end
end
