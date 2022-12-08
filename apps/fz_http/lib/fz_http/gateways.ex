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

  def get_gateway!, do: get_gateway!(name: "default")
  def get_gateway!(id: id), do: Repo.get!(Gateway, id)
  def get_gateway!(name: name), do: Repo.one!(from g in Gateway, where: g.name == ^name)

  def list_gateways, do: Repo.all(Gateway)
end
