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
