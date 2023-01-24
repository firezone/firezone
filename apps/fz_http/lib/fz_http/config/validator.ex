defmodule FzHttp.Config.Validator do
  import Ecto.Changeset
  alias FzHttp.Validator

  def validate_value(key, value, type, validate_opts) do
    validate_value_changeset(key, value, type)
    |> List.wrap()
    |> Enum.map(&maybe_validate_required(&1, key, validate_opts))
    |> Enum.flat_map(fn %{valid?: valid?, errors: errors} ->
      if valid?, do: [], else: Enum.map(errors, fn {_key, error} -> error end)
    end)
  end

  defp validate_value_changeset(key, value, {:boolean, []}) do
    {%{}, %{key => :boolean}}
    |> cast(%{key => value}, [key])
  end

  defp validate_value_changeset(key, value, {:string, opts}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> validate_length(key, opts)
  end

  defp validate_value_changeset(key, value, {:integer, opts}) do
    {%{}, %{key => :integer}}
    |> cast(%{key => value}, [key])
    |> validate_number(key, opts)
  end

  defp validate_value_changeset(key, value, {:uri, []}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> Validator.validate_uri(key)
  end

  defp validate_value_changeset(key, value, {:email, []}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> Validator.validate_email(key)
  end

  defp validate_value_changeset(key, value, {:base64_string, []}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> Validator.validate_base64(key)
  end

  defp validate_value_changeset(key, value, {:host, opts}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> Validator.validate_fqdn(key, opts)
  end

  defp validate_value_changeset(key, value, {:ip, opts}) do
    FzHttp.Config.Types.IP.changeset(key, value)
    |> FzHttp.Config.Types.IP.validate_value_changeset(key, opts)
  end

  defp validate_value_changeset(key, value, {:cidr, opts}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> Validator.validate_ip(key, opts)
  end

  defp validate_value_changeset(key, value, {:password, []}) do
    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> validate_length(key, min: 5)
  end

  defp validate_value_changeset(key, value, {:list, _separator, type}) do
    Enum.map(value, fn value ->
      validate_value_changeset(key, value, type)
    end)
  end

  defp validate_value_changeset(key, value, {:one_of, validations}) do
    changesets =
      Enum.map(validations, fn validation ->
        validate_value_changeset(key, value, validation)
      end)

    Enum.find(changesets, & &1.valid?)
    |> case do
      nil ->
        errors = Enum.flat_map(changesets, & &1.errors)
        %{List.first(changesets) | errors: errors}

      valid_changeset ->
        valid_changeset
    end

    if Enum.any?(changesets, & &1.valid?) do
      %{key => value}
    else
      %{key => {:error, "invalid value"}}
    end

    {%{}, %{key => :string}}
    |> cast(%{key => value}, [key])
    |> validate_length(key, min: 5)
  end

  defp maybe_validate_required(%Ecto.Changeset{} = changeset, key, validate_opts) do
    if Keyword.get(validate_opts, :required, false) do
      validate_required(changeset, key)
    else
      changeset
    end
  end
end
