defmodule FzHttp.Config.Validator do
  import Ecto.Changeset

  def validate(key, values, {:array, _separator, type}, opts) do
    validate(key, values, {:array, type}, opts)
  end

  def validate(key, values, {:array, type}, opts) do
    if is_list(values) do
      values
      |> Enum.map(&validate(key, &1, type, opts))
      |> Enum.reduce({true, [], []}, fn
        {:ok, value}, {valid?, values, errors} ->
          {valid?, [value] ++ values, errors}

        {:error, {value, error}}, {_valid?, values, errors} ->
          {false, values, [{value, error}] ++ errors}
      end)
      |> case do
        {true, values, []} ->
          {:ok, Enum.reverse(values)}

        {false, _values, values_and_errors} ->
          {:error, values_and_errors}
      end
    else
      {:error, {values, ["must be an array"]}}
    end
  end

  def validate(key, value, {:one_of, types}, opts) do
    types
    |> Enum.reduce_while({:error, []}, fn type, {:error, errors} ->
      case validate(key, value, type, opts) do
        {:ok, value} -> {:halt, {:ok, value}}
        {:error, {_value, type_errors}} -> {:cont, {:error, errors ++ type_errors}}
      end
    end)
    |> case do
      {:ok, value} ->
        {:ok, value}

      {:error, errors} ->
        errors =
          errors
          |> Enum.uniq()
          |> Enum.map(fn
            "is invalid" -> "must be one of: " <> Enum.join(types, ", ")
            error -> error
          end)
          |> Enum.reverse()

        {:error, {value, errors}}
    end
  end

  def validate(key, value, {:embed, type}, opts) do
    callback = Keyword.get(opts, :changeset, fn changeset, _key -> changeset end)

    changeset =
      type.changeset(value)
      |> apply_validations(callback, type, key)

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, {Map.get(changeset.changes, key, value), embedded_errors(changeset)}}
    end
  end

  def validate(key, value, type, opts) do
    callback = Keyword.get(opts, :changeset, fn changeset, _key -> changeset end)

    changeset =
      {%{}, %{key => type}}
      |> cast(%{key => value}, [key])
      |> apply_validations(callback, type, key)

    if changeset.valid? do
      {:ok, Map.fetch!(changeset.changes, key)}
    else
      {:error, {Map.get(changeset.changes, key, value), errors(changeset)}}
    end
  end

  defp apply_validations(changeset, callback, _type, key) when is_function(callback, 2) do
    callback.(changeset, key)
  end

  defp apply_validations(changeset, callback, type, key) when is_function(callback, 3) do
    callback.(type, changeset, key)
  end

  defp traverse_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp embedded_errors(changeset) do
    changeset
    |> traverse_errors()
    |> Enum.map(fn {key, error} ->
      "#{key} #{error}"
    end)
  end

  defp errors(changeset) do
    changeset
    |> traverse_errors()
    |> Map.values()
    |> List.flatten()
  end
end
