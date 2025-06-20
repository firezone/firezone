defmodule Domain.Auth.Adapters.GoogleWorkspace.Settings.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.GoogleWorkspace.Settings
  alias Domain.Auth.Adapters.OpenIDConnect

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri]a

  @key_fields ~w[type project_id
                 private_key_id private_key
                 client_email client_id
                 auth_uri token_uri auth_provider_x509_cert_url client_x509_cert_url
                 universe_domain]a

  def changeset(%Settings{} = settings, attrs) do
    changeset =
      settings
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> Domain.Repo.Changeset.trim_change(@fields)
      |> OpenIDConnect.Settings.Changeset.validate_discovery_document_uri()
      |> validate_inclusion(:response_type, ~w[code])
      |> cast_embed(:service_account_json_key,
        with: &service_account_key_changeset/2,
        required: true
      )

    Enum.reduce(Settings.scope(), changeset, fn scope, changeset ->
      validate_format(changeset, :scope, ~r/#{scope}/, message: "must include #{scope} scope")
    end)
  end

  def service_account_key_changeset(%Settings.GoogleServiceAccountKey{} = key, attrs) do
    key
    |> cast(attrs, @key_fields)
    |> validate_required(@key_fields)
  end
end
