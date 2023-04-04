defmodule Web.Auth.JSON.Authentication do
  @moduledoc """
  API Authentication implementation module for Guardian.
  """
  use Guardian, otp_app: :web

  alias Domain.{
    Auth,
    ApiTokens.ApiToken,
    ApiTokens
  }

  @impl Guardian
  def subject_for_token(%Auth.Subject{actor: {:user, user}}, _claims) do
    {:ok, user.id}
  end

  @impl Guardian
  def resource_from_claims(%{"api" => api_token_id}) do
    with {:ok, %ApiTokens.ApiToken{} = api_token} <-
           ApiTokens.fetch_unexpired_api_token_by_id(api_token_id) do
      subject = Auth.fetch_subject!(api_token, nil, nil)
      {:ok, subject}
    else
      {:error, :not_found} -> {:error, :resource_not_found}
    end
  end

  def fz_encode_and_sign(%ApiToken{} = api_token) do
    claims = %{
      "api" => api_token.id,
      "exp" => DateTime.to_unix(api_token.expires_at)
    }

    subject = Auth.fetch_subject!(api_token, nil, nil)
    Guardian.encode_and_sign(__MODULE__, subject, claims)
  end

  def get_current_subject(%Plug.Conn{} = conn) do
    __MODULE__.Plug.current_resource(conn)
  end
end
