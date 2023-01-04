defmodule FzHttp.Configurations.Configuration.SAMLIdentityProvider do
  @moduledoc """
  SAML Config virtual schema
  """
  use FzHttp, :schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :id, :string
    field :label, :string
    field :base_url, :string
    field :metadata, :string
    field :sign_requests, :boolean, default: true
    field :sign_metadata, :boolean, default: true
    field :signed_assertion_in_resp, :boolean, default: true
    field :signed_envelopes_in_resp, :boolean, default: true
    field :auto_create_users, :boolean, default: true
  end

  def changeset(struct \\ %__MODULE__{}, data) do
    struct
    |> cast(data, [
      :id,
      :label,
      :base_url,
      :metadata,
      :sign_requests,
      :sign_metadata,
      :signed_assertion_in_resp,
      :signed_envelopes_in_resp,
      :auto_create_users
    ])
    |> validate_required([
      :id,
      :label,
      :metadata,
      :auto_create_users
    ])
    |> validate_metadata()
  end

  def validate_metadata(changeset) do
    changeset
    |> validate_change(:metadata, fn :metadata, value ->
      try do
        Samly.IdpData.from_xml(value, %Samly.IdpData{})
        []
      catch
        :exit, e ->
          [metadata: "is invalid. Details: #{inspect(e)}."]
      end
    end)
  end
end
