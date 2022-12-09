defmodule FzHttp.Queries.INET do
  import Wrapped.Application

  @moduledoc """
  Raw SQL INET queries
  """

  # XXX: This needs to be an insert to avoid the deadlocks
  @next_available_ipv4_query """
  WITH combined AS (
    SELECT $2 AS ipv4
    UNION ALL
    SELECT devices.ipv4 FROM devices
  )
  SELECT combined.ipv4 + 1 AS ipv4
  FROM combined
  WHERE combined.ipv4 + 1 < host(broadcast($1))::INET
  AND combined.ipv4 + 1 != $2
  AND combined.ipv4 >= host($1)::INET
  AND NOT EXISTS (
    SELECT 1 from combined d2 WHERE d2.ipv4 = combined.ipv4 + 1
  )
  ORDER BY combined.ipv4
  LIMIT 1
  """

  # XXX: This needs to be an insert to avoid the deadlocks
  @next_available_ipv6_query """
  WITH combined AS (
    SELECT $2 AS ipv6
    UNION ALL
    SELECT devices.ipv6 FROM devices
  )
  SELECT combined.ipv6 + 1 AS ipv6
  FROM combined
  WHERE combined.ipv6 + 1 < host(broadcast($1))::INET
  AND combined.ipv6 + 1 != $2
  AND combined.ipv6 >= host($1)::INET
  AND NOT EXISTS (
    SELECT 1 from combined d2 WHERE d2.ipv6 = combined.ipv6 + 1
  )
  ORDER BY combined.ipv6
  LIMIT 1
  """

  def next_available(type) do
    network = wireguard_network(type)
    address = wireguard_address(type)
    query = next_available_query(type)

    case FzHttp.Repo.query(query, [network, address]) do
      {:ok, %Postgrex.Result{rows: [[%Postgrex.INET{} = inet]]}} ->
        inet

      {:ok, %Postgrex.Result{rows: []}} ->
        nil

      {:error, error} ->
        raise(error)
    end
  end

  defp wireguard_network(type) do
    network_key = "wireguard_#{type}_network" |> String.to_existing_atom()
    {:ok, network} = EctoNetwork.INET.cast(app().fetch_env!(:fz_http, network_key))
    network
  end

  defp wireguard_address(type) do
    address_key = "wireguard_#{type}_address" |> String.to_existing_atom()
    {:ok, address} = EctoNetwork.INET.cast(app().fetch_env!(:fz_http, address_key))
    address
  end

  defp next_available_query(:ipv4) do
    @next_available_ipv4_query
  end

  defp next_available_query(:ipv6) do
    @next_available_ipv6_query
  end
end
