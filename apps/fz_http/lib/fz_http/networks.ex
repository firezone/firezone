defmodule FzHttp.Networks do
  @moduledoc """
  The Networks context.
  """

  import Ecto.Query, warn: false

  alias FzHttp.{
    Networks.Network,
    Repo,
    Telemetry
  }

  def list_networks do
    Repo.all(Network)
  end

  def get_network!(id), do: Repo.get!(Network, id)

  def create_network(attrs \\ %{}) do
    case %Network{}
         |> Network.create_changeset(attrs)
         |> Repo.insert() do
      {:ok, network} ->
        Telemetry.add_network()
        {:ok, network}

      result ->
        result
    end
  end

  def delete_network(%Network{} = network) do
    case Repo.delete(network) do
      {:ok, network} ->
        Telemetry.delete_network()
        {:ok, network}

      result ->
        result
    end
  end
end
