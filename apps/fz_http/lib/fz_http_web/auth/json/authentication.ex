defmodule FzHttpWeb.Auth.JSON.Authentication do
  @moduledoc """
  API Authentication implementation module for Guardian.
  """
  use Guardian, otp_app: :fz_http
  alias FzHttp.Users

  @impl Guardian
  def subject_for_token(resource, _claims) do
    {:ok, to_string(resource.id)}
  end

  @impl Guardian
  def resource_from_claims(%{"sub" => id}) do
    case Users.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end
end
