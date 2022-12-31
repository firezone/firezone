defmodule FzHttp.ApiTokensFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.ApiTokens` context.
  """

  @doc """
  Generate a api_token.
  """
  def api_token(params \\ %{}) do
    user_id =
      Map.get_lazy(
        params,
        "user_id",
        fn ->
          FzHttp.UsersFixtures.user().id
        end
      )

    {:ok, api_token} =
      FzHttp.ApiTokens.create_user_api_token(%FzHttp.Users.User{id: user_id}, params)

    api_token
  end
end
