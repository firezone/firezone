defmodule FzHttp.Config.Validator do
  import Ecto.Changeset

  def validate(key, values, {:array, _separator, type, array_opts}, opts) do
    validate_array(key, values, type, array_opts, opts)
  end

  def validate(key, values, {:array, separator, type}, opts) do
    validate(key, values, {:array, separator, type, []}, opts)
  end

  def validate(key, values, {:json_array, type, array_opts}, opts) do
    validate_array(key, values, type, array_opts, opts)
  end

  def validate(key, values, {:json_array, type}, opts) do
    validate(key, values, {:json_array, type, []}, opts)
  end

  def validate(key, value, {:one_of, types}, opts) do
    types
    |> Enum.reduce_while({:error, []}, fn type, {:error, errors} ->
      case validate(key, value, type, opts) do
        {:ok, value} -> {:halt, {:ok, value}}
        {:error, {_value, type_errors}} -> {:cont, {:error, type_errors ++ errors}}
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
    _callback = Keyword.get(opts, :changeset, fn changeset, _key -> changeset end)

    changeset =
      value
      |> Map.delete(:__struct__)
      |> type.changeset()

    # TODO: we already called a changeset function
    # |> apply_validations(callback, type, key)

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
      {:ok, Map.get(changeset.changes, key)}
    else
      {:error, {Map.get(changeset.changes, key, value), errors(changeset)}}
    end
  end

  defp validate_array(_key, nil, _type, _array_opts, _opts) do
    {:ok, nil}
  end

  defp validate_array(key, values, type, array_opts, opts) when is_list(values) do
    {validate_unique, array_opts} = Keyword.pop(array_opts, :validate_unique, false)
    {validate_length, []} = Keyword.pop(array_opts, :validate_length, [])

    values
    |> Enum.map(&validate(key, &1, type, opts))
    |> Enum.reduce({true, [], []}, fn
      {:ok, value}, {valid?, values, errors} ->
        cond do
          validate_unique == true and value in values ->
            {false, values, [{value, ["should not contain duplicates"]}] ++ errors}

          true ->
            {valid?, [value] ++ values, errors}
        end

      {:error, {value, error}}, {_valid?, values, errors} ->
        {false, values, [{value, error}] ++ errors}
    end)
    |> case do
      {true, values, []} ->
        min = Keyword.get(validate_length, :min)
        max = Keyword.get(validate_length, :max)
        is = Keyword.get(validate_length, :is)

        values
        |> Enum.reverse()
        |> validate_array_length(min, max, is)

      {false, _values, values_and_errors} ->
        {:error, values_and_errors}
    end
  end

  defp validate_array(_key, values, _type, _array_opts, _opts) do
    {:error, {values, ["must be an array"]}}
  end

  defp validate_array_length(values, min, _max, _is)
       when not is_nil(min) and length(values) < min do
    {:error, {values, ["should be at least #{min} item(s)"]}}
  end

  defp validate_array_length(values, _min, max, _is)
       when not is_nil(max) and length(values) > max do
    {:error, {values, ["should be at most #{max} item(s)"]}}
  end

  defp validate_array_length(values, _min, _max, is)
       when not is_nil(is) and length(values) != is do
    {:error, {values, ["should be #{is} item(s)"]}}
  end

  defp validate_array_length(values, _min, _max, _is) do
    {:ok, values}
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
