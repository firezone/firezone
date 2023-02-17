defmodule FzHttp.Validator do
  @doc """
  A set of changeset helpers and schema extensions to simplify our changesets and make validation more reliable.
  """
  import Ecto.Changeset

  def changed?(changeset, field) do
    Map.has_key?(changeset.changes, field)
  end

  def has_errors?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end

  def validate_email(changeset, field) do
    validate_format(changeset, field, ~r/@/, message: "is invalid email address")
  end

  def validate_uri(changeset, field, opts \\ []) when is_atom(field) do
    valid_schemes = Keyword.get(opts, :schemes, ~w[http https])

    validate_change(changeset, field, fn _current_field, value ->
      case URI.new(value) do
        {:ok, %URI{} = uri} ->
          cond do
            uri.host == nil ->
              [{field, "does not contain host"}]

            uri.scheme == nil ->
              [{field, "does not contain a scheme"}]

            uri.scheme not in valid_schemes ->
              [{field, "only #{Enum.join(valid_schemes, ", ")} schemes are supported"}]

            true ->
              []
          end

        {:error, part} ->
          [{field, "is invalid. Error at #{part}"}]
      end
    end)
  end

  def normalize_url(changeset, field) do
    with {:ok, value} <- fetch_change(changeset, field) do
      uri = URI.parse(value)
      scheme = uri.scheme || "https"
      port = URI.default_port(scheme)
      path = uri.path || "/"
      put_change(changeset, field, %{uri | scheme: scheme, port: port, path: path})
    else
      :error ->
        changeset
    end
  end

  def validate_no_duplicates(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, list when is_list(list) ->
      list
      |> Enum.reduce_while({true, MapSet.new()}, fn value, {true, acc} ->
        if MapSet.member?(acc, value) do
          {:halt, {false, acc}}
        else
          {:cont, {true, MapSet.put(acc, value)}}
        end
      end)
      |> case do
        {true, _map_set} -> []
        {false, _map_set} -> [{field, "should not contain duplicates"}]
      end
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
    if Regex.match?(~r/^([a-zA-Z0-9._-])+$/i, fqdn) do
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

  defp port_validation_errors(_field, port, _allow?) when 0 < port and port <= 65_535,
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

  def validate_cidr(changeset, field, _opts \\ []) do
    validate_change(changeset, field, fn _current_field, value ->
      case FzHttp.Types.CIDR.cast(value) do
        {:ok, _cidr} ->
          []

        {:error, _reason} ->
          [{field, "is not a valid CIDR range"}]
      end
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
    validate_change(changeset, field, fn
      _field, nil -> []
      _field, [] -> []
      field, _value -> [{field, "must not be present"}]
    end)
  end

  def validate_file(changeset, field, opts \\ []) do
    validate_change(changeset, field, fn _current_field, value ->
      extensions = Keyword.get(opts, :extensions, [])

      cond do
        not File.exists?(value) ->
          [{field, "file does not exist"}]

        extensions != [] and Path.extname(value) not in extensions ->
          [
            {field,
             "file extension is not supported, got #{Path.extname(value)}, " <>
               "expected one of #{inspect(extensions)}"}
          ]

        true ->
          []
      end
    end)
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
    update_change(changeset, field, fn
      nil -> nil
      changes when is_list(changes) -> Enum.map(changes, &String.trim/1)
      change -> String.trim(change)
    end)
  end

  @doc """
  Returns `true` when binary representation of Ecto UUID is valid, otherwise - `false`.
  """
  def valid_uuid?(binary) when is_binary(binary),
    do: match?(<<_::64, ?-, _::32, ?-, _::32, ?-, _::32, ?-, _::96>>, binary)

  def valid_uuid?(_binary),
    do: false
end
