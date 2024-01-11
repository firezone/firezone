defmodule Domain.Changeset do
  import Ecto.Changeset
  alias Ecto.Changeset

  @doc """
  Changes `Ecto.Changeset` struct to convert one of `:map` fields to an embedded schema.

  If embedded changeset was valid, changes would be put back as map to the changeset field
  before the database insert. No embedded validation is performed if there already was an
  error on `field`.

  ## Why not `Ecto.Type`?

  This design is chosen over custom `Ecto.Type` because it allows us to properly build `Ecto.Changeset`
  struct and return errors in a form that will be supported by Phoenix form helpers, while the type
  doesn't allow to return multiple errors when `c:Ecto.Type.cast/2` returns an error tuple.

  ## Options

    * `:with` - callback that accepts attributes as arguments and returns a changeset
    for embedded field. Function signature: `(current_attrs, attrs) -> Ecto.Changeset.t()`.

    * `:required` - if the embed is a required field, default - `false`. Only applies on
    non-list embeds.
  """
  @spec cast_polymorphic_embed(
          changeset :: Changeset.t(),
          field :: atom(),
          opts :: [
            {:required, boolean()},
            {:with, (current_attrs :: map(), attrs :: map() -> Changeset.t())}
          ]
        ) :: Changeset.t()
  def cast_polymorphic_embed(changeset, field, opts) do
    on_cast = Keyword.fetch!(opts, :with)
    required? = Keyword.get(opts, :required, false)

    # We only support singular polymorphic embeds for now
    :map = Map.get(changeset.types, field)

    if field_invalid?(changeset, field) do
      changeset
    else
      data = Map.get(changeset.data, field)
      changes = get_change(changeset, field)

      if required? and is_nil(changes) and empty?(data) do
        add_error(changeset, field, "can't be blank", validation: :required)
      else
        %Changeset{} = nested_changeset = on_cast.(data || %{}, changes || %{})
        {changeset, original_type} = inject_embedded_changeset(changeset, field, nested_changeset)
        prepare_changes(changeset, &dump(&1, field, original_type))
      end
    end
  end

  def inject_embedded_changeset(changeset, field, nested_changeset) do
    original_type = Map.get(changeset.types, field)

    embedded_type =
      {:embed,
       %Ecto.Embedded{
         cardinality: :one,
         field: field,
         on_cast: nil,
         on_replace: :update,
         owner: %{},
         related: Map.get(changeset.data, :__struct__),
         unique: true
       }}

    nested_changeset = %{nested_changeset | action: changeset.action || :update}

    changeset = %{
      changeset
      | types: Map.put(changeset.types, field, embedded_type),
        valid?: changeset.valid? and nested_changeset.valid?,
        changes: Map.put(changeset.changes, field, nested_changeset)
    }

    {changeset, original_type}
  end

  defp field_invalid?(%Ecto.Changeset{} = changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end

  defp empty?(term), do: is_nil(term) or term == %{}

  defp dump(changeset, field, original_type) do
    map =
      changeset
      |> get_change(field)
      |> apply_action!(:dump)
      |> Ecto.embedded_dump(:json)
      |> atom_keys_to_string()

    changeset = %{changeset | types: Map.put(changeset.types, field, original_type)}

    put_change(changeset, field, map)
  end

  # We dump atoms to strings because if we persist to Postgres and read it,
  # the map will be returned with string keys, and we want to make sure that
  # the map handling is unified across the codebase.
  defp atom_keys_to_string(map) do
    for {k, v} <- map, into: %{}, do: {to_string(k), v}
  end
end
