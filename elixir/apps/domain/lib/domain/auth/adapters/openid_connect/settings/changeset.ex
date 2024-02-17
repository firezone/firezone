defmodule Domain.Auth.Adapters.OpenIDConnect.Settings.Changeset do
  use Domain, :changeset

  @fields ~w[scope
             response_type
             client_id client_secret
             discovery_document_uri]a

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
      with {:ok, %URI{scheme: scheme, host: host}}
           when not is_nil(scheme) and not is_nil(host) and host != "" <-
             URI.new(value),
           {:ok, _update_result} <- OpenIDConnect.Document.fetch_document(value) do
        []
      else
        {:ok, _uri} ->
          [{:discovery_document_uri, "is not a valid URL"}]

        {:error, %Mint.TransportError{reason: reason}} ->
          [{:discovery_document_uri, "is invalid, got #{inspect(reason)}"}]

        {:error, %Jason.DecodeError{} = _error} ->
          [{:discovery_document_uri, "is invalid, unable to parse response"}]

        # XXX: Do these occur with Mint?
        {:error, {404, _body}} ->
          [{:discovery_document_uri, "does not exist"}]

        {:error, {status, _body}} ->
          [{:discovery_document_uri, "is invalid, got #{status} HTTP response"}]

        {:error, _} ->
          [{:discovery_document_uri, "invalid URL"}]
      end
    end)
  end
end
