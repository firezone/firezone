defmodule Portal.Relay.ICECandidateIPs do
  @moduledoc """
  Extracts the IPs from ICE candidates. The Relays of the peer that receives
  the candidates only bind channels to peers the Portal has reported for the
  same account.
  """

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
