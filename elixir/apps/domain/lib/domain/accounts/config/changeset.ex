defmodule Domain.Accounts.Config.Changeset do
  use Domain, :changeset
  alias Domain.Types.IPPort
  alias Domain.Accounts.Config

  @default_dns_port 53

  def changeset(config \\ %Config{}, attrs) do
    config
    |> cast(attrs, [])
    |> cast_embed(:clients_upstream_dns, with: &client_upstream_dns_changeset/2)
    |> validate_unique_clients_upstream_dns()
  end

  defp validate_unique_clients_upstream_dns(changeset) do
    with false <- has_errors?(changeset, :clients_upstream_dns),
         {_data_or_changes, client_upstream_dns} <- fetch_field(changeset, :clients_upstream_dns) do
      addresses =
        client_upstream_dns
        |> Enum.map(&normalize_dns_address/1)
        |> Enum.reject(&is_nil/1)

      if addresses -- Enum.uniq(addresses) == [] do
        changeset
      else
        add_error(changeset, :clients_upstream_dns, "all addresses must be unique")
      end
    else
      _ -> changeset
    end
  end

  def normalize_dns_address(%Config.ClientsUpstreamDNS{protocol: :ip_port, address: address}) do
    case IPPort.cast(address) do
      {:ok, address} ->
        address
        |> IPPort.put_default_port(@default_dns_port)
        |> to_string()

      _ ->
        address
    end
  end

  def normalize_dns_address(%Config.ClientsUpstreamDNS{address: address}) do
    address
  end

  def client_upstream_dns_changeset(client_upstream_dns \\ %Config.ClientsUpstreamDNS{}, attrs) do
    client_upstream_dns
    |> cast(attrs, [:protocol, :address])
    |> validate_required([:protocol, :address])
    |> trim_change(:address)
    |> validate_inclusion(:protocol, Config.supported_dns_protocols(),
      message: "this type of DNS provider is not supported yet"
    )
    |> validate_address()
  end

  defp validate_address(changeset) do
    if has_errors?(changeset, :protocol) do
      changeset
    else
      case fetch_field(changeset, :protocol) do
        {_changes_or_data, :ip_port} -> validate_ip_port(changeset)
        :error -> changeset
      end
    end
  end

  defp validate_ip_port(changeset) do
    validate_change(changeset, :address, fn :address, address ->
      case IPPort.cast(address) do
        {:ok, _ip} -> []
        _ -> [address: "must be a valid IP address"]
      end
    end)
  end
end
