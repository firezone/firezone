defmodule Portal.Devices do
  @moduledoc """
  Domain functions for provisioning devices, shared between the admin
  LiveView (`PortalWeb.Live.Sites`) and the REST API
  (`PortalAPI.GatewayController`) so there's one source of truth for the
  "insert a gateway and mint its single-owner token" flow.
  """

  alias Portal.Authentication
  alias Portal.Device
  alias Portal.GatewayToken
  alias Portal.Site
  alias __MODULE__.Database

  @spec provision_gateway(Site.t(), String.t() | nil, Authentication.Subject.t()) ::
          {:ok, Device.t(), GatewayToken.t(), binary()} | {:error, term()}
  def provision_gateway(%Site{} = site, name, %Authentication.Subject{} = subject) do
    with {:ok, gateway} <- Database.insert_gateway(site, name, subject),
         {:ok, token} <- Authentication.create_gateway_token(gateway, subject) do
      {:ok, gateway, %{token | secret_fragment: nil}, Authentication.encode_fragment!(token)}
    end
  end

  defmodule Database do
    alias Portal.Safe

    def insert_gateway(site, name, subject) do
      %Device{
        account_id: site.account_id,
        site_id: site.id,
        type: :gateway,
        name: name || Portal.Crypto.random_token(5, encoder: :user_friendly)
      }
      |> Safe.scoped(subject)
      |> Safe.insert()
    end
  end
end
