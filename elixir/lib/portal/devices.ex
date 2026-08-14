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

    # Builds a changeset rather than a bare struct on purpose: Safe.insert/1
    # only applies the schema's own changeset/1 to changesets, not to structs
    # (see its two Scoped clauses). Inserting a struct here would skip
    # Device.changeset/1 entirely and persist names it rejects - blank,
    # whitespace-only, or longer than 255 - instead of returning the 422 the
    # provisioning endpoint documents.
    #
    # Only a nil name gets a generated one. An explicitly supplied blank
    # string is invalid input, not an omitted value, so it is validated and
    # refused rather than silently replaced.
    def insert_gateway(site, name, subject) do
      name = name || Portal.Crypto.random_token(5, encoder: :user_friendly)

      %Device{}
      |> Ecto.Changeset.cast(%{name: name}, [:name])
      |> Ecto.Changeset.put_change(:type, :gateway)
      |> Ecto.Changeset.put_change(:site_id, site.id)
      |> Safe.scoped(subject)
      |> Safe.insert()
    end
  end
end
