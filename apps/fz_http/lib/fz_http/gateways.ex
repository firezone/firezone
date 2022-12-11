defmodule FzHttp.Gateways do
  @moduledoc """
  The Gateways context.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{Gateways.Gateway, Repo}

  def create_gateway(attrs \\ %{}) do
    %Gateway{}
    |> Gateway.changeset(attrs)
    |> Repo.insert()
  end

  def update_gateway(%Gateway{} = gateway, attrs) do
    gateway
    |> Gateway.changeset(attrs)
    |> Repo.update()
  end

  def delete_gateway(%Gateway{} = gateway) do
    gateway
    |> Repo.delete()
  end

  def get_gateway!(id: id), do: Repo.get!(Gateway, id)
  def get_gateway!(name: name), do: Repo.get_by!(Gateway, name: name)
end
