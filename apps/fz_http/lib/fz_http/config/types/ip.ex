defmodule FzHttp.Config.Types.IP do
  use FzHttp.Config.Type, ecto_type: EctoNetwork.INET
  import Ecto.Changeset
  alias FzHttp.Validator

  def from_string(_source, value), do: value

  def changeset(key, value) do
    {%{}, %{key => @ecto_type}}
    |> cast(%{key => value}, [key])
  end

  def validate_value_changeset(%Ecto.Changeset{} = changeset, key, opts \\ []) do
    changeset
    |> Validator.validate_ip(key, opts)
  end
end
