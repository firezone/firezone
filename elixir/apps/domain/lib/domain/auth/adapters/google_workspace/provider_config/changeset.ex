defmodule Domain.Auth.Adapters.GoogleWorkspace.ProviderConfig.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.GoogleWorkspace.ProviderConfig
  alias Domain.Auth.Adapters.OpenIDConnect

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri]a

  def changeset(%ProviderConfig{} = settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:response_type, ~w[code])
    |> OpenIDConnect.ProviderConfig.Changeset.validate_discovery_document_uri()
    |> OpenIDConnect.ProviderConfig.Changeset.validate_scope(:scope, ProviderConfig.scope())
  end
end
