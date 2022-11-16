defmodule FzHttp.Validators.OpenIDConnect do
  @moduledoc """
  Validators various fields related to OpenID Connect
  before they're saved and passed to the underlying
  openid_connect library where they could become an issue.
  """
  import Ecto.Changeset

  def validate_discovery_document_uri(changeset) do
    changeset
    |> validate_change(:discovery_document_uri, fn :discovery_document_uri, value ->
      case OpenIDConnect.update_documents(discovery_document_uri: value) do
        {:ok, _update_result} ->
          []

        {:error, :update_documents, reason} ->
          [discovery_document_uri: "is invalid. Reason: #{inspect(reason)}"]
      end
    end)
  end
end
