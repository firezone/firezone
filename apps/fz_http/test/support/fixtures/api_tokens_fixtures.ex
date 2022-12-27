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
      |> FzHttp.ApiTokens.create_user_api_token(%FzHttp.Users.User{id: user_id})

    api_token
  end
end
