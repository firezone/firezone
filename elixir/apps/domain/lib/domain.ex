defmodule Domain do
  @moduledoc """
  This module provides a common interface for all the domain modules,
  making sure our code structure is consistent and predictable.
  """

  def schema do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id

      @timestamps_opts [type: :utc_datetime_usec]

      @type id :: binary()
    end
  end

  def changeset do
    quote do
      import Ecto.Changeset
      import Domain.Repo.Changeset
      import Domain.Repo, only: [valid_uuid?: 1]
    end
  end

  def query do
    quote do
      import Ecto.Query
      import Domain.Repo.Query

      @behaviour Domain.Repo.Query
    end
  end

  def struct_from_params(schema_module, params) do
    schema_module.__schema__(:fields)
    |> Enum.reduce(struct(schema_module), fn field, acc ->
      case Map.get(params, to_string(field)) do
        nil ->
          acc

        value ->
          field_type = schema_module.__schema__(:type, field)

          case Ecto.Type.cast(field_type, value) do
            {:ok, casted_value} -> Map.put(acc, field, casted_value)
            :error -> acc
          end
      end
    end)
  end

  @doc """
  When used, dispatch to the appropriate schema/context/changeset/query/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
