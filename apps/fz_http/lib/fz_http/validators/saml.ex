defmodule FzHttp.Validators.SAML do
  @moduledoc """
  Validators for SAML configs.
  """

  alias Samly.IdpData
  import Ecto.Changeset

  def validate_metadata(changeset) do
    changeset
    |> validate_change(:metadata, fn :metadata, value ->
      try do
        IdpData.from_xml(value, %IdpData{})
        []
      catch
        :exit, e ->
          [metadata: "is invalid. Details: #{inspect(e)}."]
      end
    end)
  end
end
