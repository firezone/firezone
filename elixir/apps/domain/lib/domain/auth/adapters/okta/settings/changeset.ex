defmodule Domain.Auth.Adapters.Okta.Settings.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.Okta.Settings
  alias Domain.Auth.Adapters.OpenIDConnect

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri
             okta_account_domain
             api_base_url]a

  def changeset(%Settings{} = settings, attrs) do
    changeset =
      settings
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> trim_fields()
      |> OpenIDConnect.Settings.Changeset.validate_discovery_document_uri()
      |> validate_inclusion(:response_type, ~w[code])

    Enum.reduce(Settings.scope(), changeset, fn scope, changeset ->
      validate_format(changeset, :scope, ~r/#{scope}/, message: "must include #{scope} scope")
    end)
  end

  defp trim_fields(changeset) do
    changeset
    |> Domain.Repo.Changeset.trim_change(:response_type)
    |> Domain.Repo.Changeset.trim_change(:client_id)
    |> Domain.Repo.Changeset.trim_change(:client_secret)
    |> Domain.Repo.Changeset.trim_change(:discovery_document_uri)
    |> Domain.Repo.Changeset.trim_change(:okta_account_domain)
    |> Domain.Repo.Changeset.trim_change(:api_base_url)
  end
end
