defmodule Portal.Relay.ICECandidateIPs do
  @moduledoc """
  Reports the IPs seen in ICE candidates to the Relays of the peer that receives
  them, which only bind channels to peers the Portal has reported for the same
  account.
  """

  alias Portal.PG

  @spec report(Enumerable.t(), String.t(), [String.t()]) :: :ok
  def report(relay_ids, account_id, candidates) do
    case extract(candidates) do
      [] ->
        :ok

      ips ->
        Enum.each(relay_ids, fn relay_id ->
          PG.deliver(relay_id, {:ice_candidate_ips, account_id, ips})
        end)
    end
  end

  @spec extract([String.t()]) :: [String.t()]
  def extract(candidates) do
    candidates
    |> Enum.flat_map(&candidate_ip/1)
    |> Enum.uniq()
  end

  defp candidate_ip(candidate) when is_binary(candidate) do
    with [_foundation, _component, _transport, _priority, address | _] <-
           String.split(candidate),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(address)) do
      [ip |> :inet.ntoa() |> List.to_string()]
    else
      _ -> []
    end
  end

  defp candidate_ip(_candidate), do: []
end
