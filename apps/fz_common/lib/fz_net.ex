defmodule FzCommon.FzNet do
  @moduledoc """
  Network utility functions.
  """
  import FzCommon.FzRegex

  # XXX: Consider using CIDR for this
  def ip_type(str) when is_binary(str) do
    charlist =
      str
      # remove CIDR range if exists
      |> String.split("/")
      |> List.first()
      |> String.to_charlist()

    case :inet.parse_ipv4_address(charlist) do
      {:ok, _} ->
        "IPv4"

      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, _} -> "IPv6"
          {:error, _} -> "unknown"
        end
    end
  end

  def valid_cidr?(cidr) when is_binary(cidr) do
    String.match?(cidr, cidr4_regex()) or String.match?(cidr, cidr6_regex())
  end

  def valid_ip?(ip) when is_binary(ip) do
    String.match?(ip, ip_regex())
  end

  @doc """
  Standardize IP addresses and CIDR ranges so that they can be condensed / shortened.
  """
  def standardized_inet(inet) when is_binary(inet) do
    if String.contains?(inet, "/") do
      inet
      # normalize CIDR
      |> CIDR.parse()
      |> to_string()
    else
      {:ok, addr} = inet |> String.to_charlist() |> :inet.parse_address()
      :inet.ntoa(addr) |> List.to_string()
    end
  end

  def inet_to_ip_with_mask(%{address: address, netmask: netmask} = inet, network) do
    if netmask != nil do
      inet
    else
      "#{address |> Tuple.to_list() |> Enum.join(".")}/#{get_range!(network)}"
    end
  end

  def get_range!(inet) when is_binary(inet) do
    case String.split(inet, "/") do
      [_, mask] -> mask
      _ -> raise "inet given #{inet} doesn't have a range"
    end
  end

  def valid_fqdn?(fqdn) when is_binary(fqdn) do
    String.match?(fqdn, fqdn_regex())
  end

  def valid_hostname?(hostname) when is_binary(hostname) do
    String.match?(hostname, host_regex())
  end

  def to_complete_url(str) when is_binary(str) do
    case URI.new(str) do
      {:ok, %{host: nil, scheme: nil}} ->
        {:ok, "https://" <> str}

      {:ok, _} ->
        {:ok, str}

      err ->
        err
    end
  end

  def endpoint_to_ip(endpoint) do
    endpoint
    |> String.replace(~r{:\d+$}, "")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end
end
