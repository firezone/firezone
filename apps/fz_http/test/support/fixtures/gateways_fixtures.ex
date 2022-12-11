defmodule FzHttp.GatewaysFixtures do
  @moduledoc """
  Test helpers for creating gateways with the `FzHttp.Gateways` context.
  """

  alias FzHttp.Gateways

  @doc """
  Generate a `Gateway`.
  """
  def gateway(attrs \\ %{}) do
    {:ok, gateway} =
      gateway_gen_attrs()
      |> Map.merge(attrs)
      |> Gateways.create_gateway()

    gateway
  end

  def gateway_gen_attrs do
    %{
      name: "gateway-#{counter()}",
      registration_token: FzCommon.FzCrypto.rand_token(),
      registration_token_created_at: DateTime.utc_now()
    }
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
