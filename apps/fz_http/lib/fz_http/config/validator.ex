defmodule FzHttp.Config.Validator do
  import Ecto.Changeset

  def validate(key, value, {:array, _separator, type}, opts) do
    Enum.map(value, fn value ->
      validate(key, value, type, opts)
    end)
  end

  def validate(key, value, {:one_of, types}, opts) do
    results =
      Enum.map(types, fn type ->
        validate(key, value, type, opts)
      end)

    case Enum.find(results, fn {_value, errors} -> errors == [] end) do
      nil ->
        {value, Enum.flat_map(results, &elem(&1, 1))}

      {value, []} ->
        {value, []}
    end
  end

  def validate(key, value, type, opts) do
    callback = Keyword.get(opts, :changeset, fn changeset, _key -> changeset end)

    changeset =
      {%{}, %{key => type}}
      |> cast(%{key => value}, [key])
      |> apply_validations(callback, type, key)

    {Map.get(changeset.changes, key), Keyword.values(changeset.errors)}
  end

  defp apply_validations(changeset, callback, _type, key) when is_function(callback, 2) do
    callback.(changeset, key)
  end

  defp apply_validations(changeset, callback, type, key) when is_function(callback, 3) do
    callback.(type, changeset, key)
  end
end
