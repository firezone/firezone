defmodule Domain.Config.ClientsUpstreamDNS do
  @moduledoc """
  Embedded Schema for Clients Upstream DNS
  """
  use Domain, :schema
  import Domain.Validator
  import Ecto.Changeset

  @dns_types ~w[ip dns_over_tls dns_over_http]

  @primary_key false
  embedded_schema do
    field :type, :string
    field :address, :string
  end

  def changeset(dns_config \\ %__MODULE__{}, attrs) do
    dns_config
    |> cast(attrs, [:type, :address])
    |> validate_required([:type, :address])
    |> trim_change(:address)
    |> validate_address()
  end

  defp validate_address(changeset) do
    {_origin, type} = fetch_field(changeset, :type)

    validate_change(changeset, :address, fn :address, address ->
      case type do
        "ip" ->
          case Domain.Types.IPPort.cast(address) do
            {:ok, _ip} ->
              []

            {:error, _reason} ->
              [address: "must be a valid IP address"]
          end

        "dns_over_tls" ->
          [address: "DNS over TLS is not supported yet"]

        "dns_over_http" ->
          [address: "DNS over HTTP is not supported yet"]

        _other ->
          [address: "Invalid Type"]
      end
    end)
  end

  # def normalize_dns_address(dns) do
  #  case Domain.Types.IPPort.cast(dns.address) do
  #    {:ok, ip} ->
  #      port = ip.port || 53
  #      %{ip | port: port} |> to_string()

  #    {:error, _reason} ->
  #      dns.address

  #    :error ->
  #      dns.address
  #  end
  # end

  def normalize_dns_address(%__MODULE__{type: "ip", address: address}) do
    case Domain.Types.IPPort.cast(address) do
      {:ok, ip} ->
        port = ip.port || 53
        %{ip | port: port} |> to_string()

      {:error, _reason} ->
        address
    end
  end

  def normalize_dns_address(%__MODULE__{type: "dns_over_tls", address: address}) do
    address
  end

  def normalize_dns_address(%__MODULE__{type: "dns_over_http", address: address}) do
    address
  end

  # def changeset(logo \\ %__MODULE__{}, attrs) do
  #  logo
  #  |> cast(attrs, [:url, :data, :file, :type])
  #  |> validate_file(:file, extensions: @whitelisted_file_extensions)
  #  |> move_file_to_static
  # end

  # defp move_file_to_static(changeset) do
  #  case fetch_change(changeset, :file) do
  #    {:ok, file} ->
  #      directory = Path.join(Application.app_dir(:domain), "priv/static/uploads/logo")
  #      file_name = Path.basename(file)
  #      file_path = Path.join(directory, file_name)
  #      File.mkdir_p!(directory)
  #      File.cp!(file, file_path)
  #      put_change(changeset, :file, file_name)

  #    :error ->
  #      changeset
  #  end
  # end
end
