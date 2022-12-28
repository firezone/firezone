defmodule FzHttpWeb.Auth.JSON.Authentication do
  @moduledoc """
  API Authentication implementation module for Guardian.
  """
  use Guardian, otp_app: :fz_http

  alias FzHttp.{
    ApiTokens.ApiToken,
    ApiTokens,
    Users.User,
    Users
  }

  @impl Guardian
  def subject_for_token(user, _claims) do
    {:ok, user.id}
  end

  @impl Guardian
  def resource_from_claims(%{"api" => api_token_id}) do
    with %ApiTokens.ApiToken{} = api_token <- ApiTokens.get_unexpired_api_token(api_token_id),
         %Users.User{} = user <- Users.get_user(api_token.user_id) do
      {:ok, user}
    else
      _ ->
        {:error, :resource_not_found}
    end
  end

  def fz_encode_and_sign(%ApiToken{} = api_token, %User{} = user) do
    claims = %{
      "api" => api_token.id,
      "exp" => DateTime.to_unix(api_token.expires_at)
    }

    Guardian.encode_and_sign(__MODULE__, user, claims)
  end
end
