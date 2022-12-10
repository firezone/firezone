defmodule FzHttp.GatewaysFixtures do
  @moduledoc """
  Test helpers for creating gateways with the `FzHttp.Gateways` context.
  """

  alias FzHttp.{Repo, Gateways, Gateways.Gateway}

  @doc """
  Generate a `Gateway`, using "default" name if not specified.
  """
  def gateway(attrs \\ %{}) do
    name = attrs[:name] || "default"

    case Repo.get_by(Gateway, name: name) do
      nil ->
        {:ok, gateway} =
          Gateways.create_gateway(%{
            name: name,
            registration_token: "test_token",
            registration_token_created_at: DateTime.utc_now()
          })

        gateway

      %Gateway{} = gateway ->
        gateway
    end
  end
end
