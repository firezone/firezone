defmodule API.IdentityProviderController do
  use API, :controller
  import API.ControllerHelpers
  alias Domain.Auth

  action_fallback API.FallbackController

  def index(conn, params) do
    list_opts = params_to_list_opts(params)

    with {:ok, identity_providers, metadata} <-
           Auth.list_providers(conn.assigns.subject, list_opts) do
      render(conn, :index, identity_providers: identity_providers, metadata: metadata)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, identity_provider} <- Auth.fetch_provider_by_id(id, conn.assigns.subject) do
      render(conn, :show, identity_provider: identity_provider)
    end
  end

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, identity_provider} <- Auth.fetch_provider_by_id(id, subject),
         {:ok, identity_provider} <- Auth.delete_provider(identity_provider, subject) do
      render(conn, :show, identity_provider: identity_provider)
    end
  end
end
