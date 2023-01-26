defmodule FzHttp.Validator do
  @doc """
  A set of changeset helpers and schema extensions to simplify our changesets and make validation more reliable.
  """
  import Ecto.Changeset
  alias FzCommon.FzNet

  def changed?(changeset, field) do
    Map.has_key?(changeset.changes, field)
  end

  def has_errors?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end

  def validate_email(changeset, field) do
    validate_format(changeset, field, ~r/@/, message: "is invalid email address")
  end

  def validate_uri(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, accumulated_changeset ->
      validate_uri(accumulated_changeset, field)
    end)
  end

  def validate_uri(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      case URI.new(value) do
        {:error, part} ->
          [{field, "is invalid. Error at #{part}"}]

        _ ->
          []
      end
    end)
  end

  def validate_no_duplicates(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      values = split_comma_list(value)
      dupes = Enum.uniq(values -- Enum.uniq(values))

      error_if(
        dupes,
        &(&1 != []),
        &{field, "is invalid: duplicates are not allowed: #{Enum.join(&1, ", ")}"}
      )
    end)
  end

  def validate_fqdn(changeset, field, opts \\ []) do
    allow_port = Keyword.get(opts, :allow_port, false)

    validate_change(changeset, field, fn _current_field, value ->
      {fqdn, port} = split_port(value)
      fqdn_validation_errors = fqdn_validation_errors(field, fqdn)
      port_validation_errors = port_validation_errors(field, port, allow_port)
      fqdn_validation_errors ++ port_validation_errors
    end)
  end

  defp fqdn_validation_errors(field, fqdn) do
    if FzNet.valid_fqdn?(fqdn) do
      []
    else
      [{field, "#{fqdn} is not a valid FQDN"}]
    end
  end

  defp split_port(value) do
    case String.split(value, ":", parts: 2) do
      [prefix, port] ->
        case Integer.parse(port) do
          {port, ""} ->
            {prefix, port}

          _ ->
            {value, nil}
        end

      [value] ->
        {value, nil}
    end
  end

  defp port_validation_errors(_field, nil, _allow?),
    do: []

  defp port_validation_errors(field, _port, false),
    do: [{field, "setting port is not allowed"}]

  defp port_validation_errors(field, port, _allow?) when 0 < port and port <= 65_535,
    do: []

  defp port_validation_errors(field, _port, _allow?),
    do: [{field, "port is not a number between 0 and 65535"}]

  def validate_ip_type_inclusion(changeset, field, types) do
    validate_change(changeset, field, fn _current_field, %{address: address} ->
      type = if tuple_size(address) == 4, do: :ipv4, else: :ipv6

      if type in types do
        []
      else
        [{field, "is not a supported IP type"}]
      end
    end)
  end

  def required_ip_port(changeset, field) do
    validate_change(changeset, field, fn _current_field, %{address: address, port: port} ->
      if port do
        []
      else
        [{field, "is required"}]
      end
    end)
  end

  def validate_cidr(changeset, field, _opts \\ []) do
    validate_change(changeset, field, fn _current_field, value ->
      if FzNet.valid_cidr?(value) do
        []
      else
        [{field, "#{value} is not a valid CIDR range"}]
      end
    end)
  end

  def validate_list_of_ips(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> split_comma_list()
      |> Enum.find(&(not FzNet.valid_ip?(&1)))
      |> error_if(
        &(!is_nil(&1)),
        &{field, "is invalid: #{&1} is not a valid IPv4 / IPv6 address"}
      )
    end)
  end

  def validate_list_of_ips_or_cidrs(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> split_comma_list()
      |> Enum.find(&(not (FzNet.valid_ip?(&1) or FzNet.valid_cidr?(&1))))
      |> error_if(
        &(!is_nil(&1)),
        &{field, "is invalid: #{&1} is not a valid IPv4 / IPv6 address or CIDR range"}
      )
    end)
  end

  def validate_base64(changeset, field) do
    validate_change(changeset, field, fn _cur, value ->
      case Base.decode64(value) do
        :error -> [{field, "must be a base64-encoded string"}]
        {:ok, _decoded} -> []
      end
    end)
  end

  def validate_omitted(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, accumulated_changeset ->
      validate_omitted(accumulated_changeset, field)
    end)
  end

  def validate_omitted(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      if is_nil(value) do
        []
      else
        [{field, "must not be present"}]
      end
    end)
  end

  defp split_comma_list(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp error_if(value, is_error, error) do
    if is_error.(value) do
      [error.(value)]
    else
      []
    end
  end

  @doc """
  Takes value from `value_field` and puts it's hash to `hash_field`.
  """
  def put_hash(%Ecto.Changeset{} = changeset, value_field, to: hash_field) do
    with {:ok, value} when is_binary(value) and value != "" <-
           fetch_change(changeset, value_field) do
      put_change(changeset, hash_field, FzCommon.FzCrypto.hash(value))
    else
      _ -> changeset
    end
  end

  @doc """
  Validates that value in a given `value_field` equals to hash stored in `hash_field`.
  """
  def validate_hash(changeset, value_field, hash_field: hash_field) do
    with {:data, hash} <- fetch_field(changeset, hash_field) do
      validate_change(changeset, value_field, fn value_field, token ->
        if FzCommon.FzCrypto.equal?(token, hash) do
          []
        else
          [{value_field, {"is invalid", [validation: :hash]}}]
        end
      end)
    else
      {:changes, _hash} ->
        add_error(changeset, value_field, "can not be verified", validation: :hash)

      :error ->
        add_error(changeset, value_field, "is already verified", validation: :hash)
    end
  end

  def validate_if_true(%Ecto.Changeset{} = changeset, field, callback)
      when is_function(callback, 1) do
    case fetch_field(changeset, field) do
      {_data_or_changes, true} ->
        callback.(changeset)

      _else ->
        changeset
    end
  end

  def validate_if_changed(%Ecto.Changeset{} = changeset, field, callback)
      when is_function(callback, 1) do
    with {:ok, _value} <- fetch_change(changeset, field) do
      callback.(changeset)
    else
      _ -> changeset
    end
  end

  @doc """
  Removes change for a given field and original value from it from `changeset.params`.

  Even though `changeset.params` considered to be a private field it leaks values even
  after they are removed from a changeset if you `inspect(struct, structs: false)` or
  just access it directly.
  """
  def redact_field(%Ecto.Changeset{} = changeset, field) do
    changeset = delete_change(changeset, field)
    %{changeset | params: Map.drop(changeset.params, field_variations(field))}
  end

  defp field_variations(field) when is_atom(field), do: [field, Atom.to_string(field)]

  @doc """
  Puts the change if field is not changed or it's value is set to `nil`.
  """
  def put_default_value(changeset, _field, nil) do
    changeset
  end

  def put_default_value(changeset, field, value) do
    case fetch_field(changeset, field) do
      {:data, nil} -> put_change(changeset, field, maybe_apply(value))
      :error -> put_change(changeset, field, maybe_apply(value))
      _ -> changeset
    end
  end

  defp maybe_apply(fun) when is_function(fun, 0), do: fun.()
  defp maybe_apply(value), do: value

  def trim_change(changeset, field) do
    update_change(changeset, field, &if(!is_nil(&1), do: String.trim(&1)))
  end

  @doc """
  Returns `true` when binary representation of Ecto UUID is valid, otherwise - `false`.
  """
  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false
end
