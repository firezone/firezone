defmodule FzHttp.Queries.INET do
  @moduledoc """
  Raw SQL INET queries
  """

  @next_available_ipv4_query """
  SELECT COALESCE(
    (
      SELECT devices.ipv4 + 1
      FROM devices
      WHERE devices.ipv4 < host(broadcast($1))::INET
      AND devices.ipv4 + 1 != $2
      AND devices.ipv4 >= host($1)::INET
      AND NOT EXISTS (
        SELECT 1 from devices d2 WHERE d2.ipv4 = devices.ipv4 + 1
      )
      ORDER BY devices.ipv4
      LIMIT 1
    ),
    CASE WHEN host($1)::INET + 1 << $1 AND host($1)::INET + 1 != $2 THEN host($1)::INET + 1
         WHEN host($1)::INET + 2 << $1 THEN host($1)::INET + 2
         ELSE NULL
    END
  )
  """

  @next_available_ipv6_query """
  SELECT COALESCE(
    (
      SELECT devices.ipv6 + 1
      FROM devices
      WHERE devices.ipv6 < host(broadcast($1))::INET
      AND devices.ipv6 + 1 != $2
      AND devices.ipv6 >= host($1)::INET
      AND NOT EXISTS (SELECT 1 from devices d2 WHERE d2.ipv6 = devices.ipv6 + 1)
      ORDER BY devices.ipv6
      LIMIT 1
    ),
    CASE WHEN host($1)::INET + 1 << $1 AND host($1)::INET + 1 != $2 THEN host($1)::INET + 1
         WHEN host($1)::INET + 2 << $1 THEN host($1)::INET + 2
         ELSE NULL
    END
  )
  """

  def next_available(type) do
    network = wireguard_network(type)
    address = wireguard_address(type)
    query = next_available_query(type)

    case FzHttp.Repo.query(query, [network, address]) do
      {:ok, %Postgrex.Result{} = result} ->
        [[%Postgrex.INET{} = inet | _fields] | _rows] = result.rows
        inet

      {:error, error} ->
        raise(error)
    end
  end

  defp wireguard_network(type) do
    network_key = "wireguard_#{type}_network" |> String.to_existing_atom()
    {:ok, network} = EctoNetwork.INET.cast(Application.fetch_env!(:fz_http, network_key))
    network
  end

  defp wireguard_address(type) do
    address_key = "wireguard_#{type}_address" |> String.to_existing_atom()
    {:ok, address} = EctoNetwork.INET.cast(Application.fetch_env!(:fz_http, address_key))
    address
  end

  defp next_available_query(:ipv4) do
    @next_available_ipv4_query
  end

  defp next_available_query(:ipv6) do
    @next_available_ipv6_query
  end
end
