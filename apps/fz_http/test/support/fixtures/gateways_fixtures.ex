defmodule FzHttp.GatewaysFixtures do
  @moduledoc """
  Test helpers for creating gateways with the `FzHttp.Gateways` context.
  """

  alias FzHttp.Gateways

  @public_key "VDDVTr/R78C3p6STeSecqfEEltJtGduFajFjXPIA6wI="

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

  def setup_default_gateway() do
    case Gateways.create_default_gateway(%{public_key: @public_key}) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  def gateway_gen_attrs do
    %{
      name: "gateway-#{counter()}",
      public_key: @public_key
    }
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
