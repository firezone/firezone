defmodule Portal.SchemaHelpers do
  @doc """
  Converts a map of string params to a schema struct with values casted.
  Uses Ecto changesets for robust casting that handles all Ecto features.
  """
  def struct_from_params(schema_module, params) do
    # Get schema metadata
    fields = schema_module.__schema__(:fields)
    embeds = schema_module.__schema__(:embeds)

    # Build a minimal changeset module dynamically
    changeset_fn = fn struct, attrs ->
      struct
      |> Ecto.Changeset.cast(attrs, fields -- embeds)
      |> cast_all_embeds(schema_module, embeds)
    end

    # Apply the changeset
    schema_module
    |> struct()
    |> changeset_fn.(params)
    |> Ecto.Changeset.apply_changes()
  end

  @doc """
  Folds a struct rebuilt from the WAL onto the copy a process already holds,
  keeping the state that only lives in that process.

  `struct_from_params/2` casts persisted fields and embeds, so a broadcast
  struct carries neither virtual fields (which are not in `__schema__(:fields)`)
  nor associations (which arrive `NotLoaded`). Assigning one wholesale silently
  resets both. `preserve` names any persisted columns the holder also owns, for
  values written to the database later than they are known in memory.
  """
  def merge_broadcast(%module{} = current, %module{} = broadcast, preserve \\ []) do
    broadcast =
      Enum.reduce(module.__schema__(:virtual_fields) ++ preserve, broadcast, fn field, struct ->
        Map.replace!(struct, field, Map.fetch!(current, field))
      end)

    Enum.reduce(module.__schema__(:associations), broadcast, fn assoc, struct ->
      case Map.fetch!(current, assoc) do
        %Ecto.Association.NotLoaded{} -> struct
        loaded -> Map.replace!(struct, assoc, loaded)
      end
    end)
  end

  # Cast all embedded fields
  defp cast_all_embeds(changeset, schema_module, embeds) do
    Enum.reduce(embeds, changeset, fn embed_field, acc ->
      embed_type = schema_module.__schema__(:embed, embed_field)

      case embed_type do
        %Ecto.Embedded{cardinality: :one} ->
          Ecto.Changeset.cast_embed(acc, embed_field, with: &embedded_changeset/2)

        %Ecto.Embedded{cardinality: :many} ->
          Ecto.Changeset.cast_embed(acc, embed_field, with: &embedded_changeset/2)

        _ ->
          acc
      end
    end)
  end

  # Generic changeset function for embedded schemas
  defp embedded_changeset(struct, params) do
    schema_module = struct.__struct__
    fields = schema_module.__schema__(:fields)
    embeds = schema_module.__schema__(:embeds)

    struct
    |> Ecto.Changeset.cast(params, fields -- embeds)
    |> cast_all_embeds(schema_module, embeds)
  end
end
