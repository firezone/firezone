defmodule Domain.Auth.Adapters.OpenIDConnect.Settings.Changeset do
  use Domain, :changeset
  alias Domain.Auth.Adapters.OpenIDConnect.Settings

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri]a

  def create_changeset(attrs) do
    changeset(%Settings{}, attrs)
  end

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_discovery_document_uri()
    |> validate_inclusion(:response_type, ~w[code])
    |> validate_format(:scope, ~r/openid/, message: "must include openid scope")
  end

  def validate_discovery_document_uri(changeset) do
    validate_change(changeset, :discovery_document_uri, fn :discovery_document_uri, value ->
      with {:ok, %URI{scheme: scheme, host: host}} when not is_nil(scheme) and not is_nil(host) <-
             URI.new(value),
           {:ok, _update_result} <- OpenIDConnect.Document.fetch_document(value) do
        []
      else
        {:ok, _uri} ->
          [{:discovery_document_uri, "is not a valid URL"}]

        {:error, reason} ->
          [{:discovery_document_uri, "is invalid. Reason: #{inspect(reason)}"}]
      end
    end)
  end
end
