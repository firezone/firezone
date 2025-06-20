defmodule Domain.Auth.Adapters.MicrosoftEntra.Settings.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.MicrosoftEntra.Settings
  alias Domain.Auth.Adapters.OpenIDConnect

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri]a

  def changeset(%Settings{} = settings, attrs) do
    changeset =
      settings
      |> cast(attrs, @fields)
      |> validate_required(@fields)
      |> Domain.Repo.Changeset.trim_change(@fields)
      |> OpenIDConnect.Settings.Changeset.validate_discovery_document_uri()
      |> validate_inclusion(:response_type, ~w[code])

    Enum.reduce(Settings.scope(), changeset, fn scope, changeset ->
      validate_format(changeset, :scope, ~r/#{scope}/, message: "must include #{scope} scope")
    end)
  end
end
