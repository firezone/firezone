defmodule FzHttp.TunnelsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.Tunnels` context.
  """

  alias FzHttp.{Tunnels, UsersFixtures}

  @doc """
  Generate a tunnel.
  """
  def tunnel(attrs \\ %{}) do
    # Don't create a user if user_id is passed
    user_id = Map.get_lazy(attrs, :user_id, fn -> UsersFixtures.user().id end)

    default_attrs = %{
      user_id: user_id,
      public_key: "test-pubkey",
      name: "factory"
    }

    {:ok, tunnel} = Tunnels.create_tunnel(Map.merge(default_attrs, attrs))
    tunnel
  end
end
