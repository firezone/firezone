defmodule FzHttp.ApiTokensFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.ApiTokens` context.
  """

  @doc """
  Generate a api_token.
  """
  def api_token_fixture(attrs \\ %{}) do
    user_id =
      Map.get_lazy(
        attrs,
        :user_id,
        fn ->
          FzHttp.UsersFixtures.user().id
        end
      )

    {:ok, api_token} =
      attrs
      |> Enum.into(%{
        user_id: user_id,
        revoked_at: ~U[2022-11-25 04:48:00.000000Z]
      })
      |> FzHttp.ApiTokens.create_api_token()

    api_token
  end
end
