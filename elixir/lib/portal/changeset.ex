defmodule Portal.Changeset do
  @moduledoc """
  Extends `Ecto.Changeset` with custom validations.
  """
  import Ecto.Changeset

  @special_use_ipv4_cidrs [
    %Postgrex.INET{address: {0, 0, 0, 0}, netmask: 8},
    %Postgrex.INET{address: {10, 0, 0, 0}, netmask: 8},
    %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10},
    %Postgrex.INET{address: {127, 0, 0, 0}, netmask: 8},
    %Postgrex.INET{address: {169, 254, 0, 0}, netmask: 16},
    %Postgrex.INET{address: {172, 16, 0, 0}, netmask: 12},
    %Postgrex.INET{address: {192, 0, 0, 0}, netmask: 24},
    %Postgrex.INET{address: {192, 0, 2, 0}, netmask: 24},
    %Postgrex.INET{address: {192, 31, 196, 0}, netmask: 24},
    %Postgrex.INET{address: {192, 52, 193, 0}, netmask: 24},
    %Postgrex.INET{address: {192, 88, 99, 0}, netmask: 24},
    %Postgrex.INET{address: {192, 168, 0, 0}, netmask: 16},
    %Postgrex.INET{address: {192, 175, 48, 0}, netmask: 24},
    %Postgrex.INET{address: {198, 18, 0, 0}, netmask: 15},
    %Postgrex.INET{address: {198, 51, 100, 0}, netmask: 24},
    %Postgrex.INET{address: {203, 0, 113, 0}, netmask: 24},
    %Postgrex.INET{address: {224, 0, 0, 0}, netmask: 4},
    %Postgrex.INET{address: {240, 0, 0, 0}, netmask: 4}
  ]

  @special_use_ipv6_cidrs [
    # ::/96 (which subsumes :: and ::1) and ::ffff:0:0:0/96 are deprecated
    # formats that embed an arbitrary IPv4 address.
    %Postgrex.INET{address: {0, 0, 0, 0, 0, 0, 0, 0}, netmask: 96},
    %Postgrex.INET{address: {0, 0, 0, 0, 0xFFFF, 0, 0, 0}, netmask: 96},
    %Postgrex.INET{address: {0x0064, 0xFF9B, 0, 0, 0, 0, 0, 0}, netmask: 96},
    %Postgrex.INET{address: {0x0064, 0xFF9B, 0x0001, 0, 0, 0, 0, 0}, netmask: 48},
    %Postgrex.INET{address: {0x0100, 0, 0, 0, 0, 0, 0, 0}, netmask: 64},
    %Postgrex.INET{address: {0x2001, 0, 0, 0, 0, 0, 0, 0}, netmask: 32},
    %Postgrex.INET{address: {0x2001, 0x0002, 0, 0, 0, 0, 0, 0}, netmask: 48},
    %Postgrex.INET{address: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, netmask: 32},
    %Postgrex.INET{address: {0x2001, 0x0020, 0, 0, 0, 0, 0, 0}, netmask: 28},
    %Postgrex.INET{address: {0x2002, 0, 0, 0, 0, 0, 0, 0}, netmask: 16},
    %Postgrex.INET{address: {0xFC00, 0, 0, 0, 0, 0, 0, 0}, netmask: 7},
    %Postgrex.INET{address: {0xFE80, 0, 0, 0, 0, 0, 0, 0}, netmask: 10},
    %Postgrex.INET{address: {0xFEC0, 0, 0, 0, 0, 0, 0, 0}, netmask: 10},
    %Postgrex.INET{address: {0xFF00, 0, 0, 0, 0, 0, 0, 0}, netmask: 8}
  ]

  # Helpers

  def set_action(changesets, action) when is_list(changesets) do
    Enum.map(changesets, &set_action(&1, action))
  end

  def set_action(%Ecto.Changeset{} = changeset, action) do
    assocs =
      Enum.flat_map(changeset.types, fn
        {field, {:assoc, _params}} -> [field]
        {field, {:embed, _params}} -> [field]
        _ -> []
      end)

    changeset =
      Enum.reduce(changeset.changes, changeset, fn {key, value}, changeset ->
        if key in assocs do
          %{changeset | changes: Map.put(changeset.changes, key, set_action(value, action))}
        else
          changeset
        end
      end)

    %{changeset | action: action}
  end

  def set_action(other, _action) do
    other
  end

  def has_errors?(%Ecto.Changeset{} = changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end

  def empty?(%Ecto.Changeset{} = changeset), do: Enum.empty?(changeset.changes)
  def empty?(%{}), do: true

  def empty?(%Ecto.Changeset{} = changeset, field) do
    case fetch_field(changeset, field) do
      :error -> true
      {_data_or_changes, nil} -> true
      {_data_or_changes, _value} -> false
    end
  end

  @doc """
  Puts the change if field is not changed or its value is set to `nil`.
  """
  def put_default_value(%Ecto.Changeset{} = changeset, _field, nil) do
    changeset
  end

  def put_default_value(%Ecto.Changeset{} = changeset, field, from: source_field) do
    case fetch_field(changeset, source_field) do
      {_data_or_changes, value} -> put_default_value(changeset, field, value)
      :error -> changeset
    end
  end

  def put_default_value(%Ecto.Changeset{} = changeset, field, value) do
    case fetch_field(changeset, field) do
      {:data, nil} -> put_change(changeset, field, maybe_apply(changeset, value))
      :error -> put_change(changeset, field, maybe_apply(changeset, value))
      _ -> changeset
    end
  end

  defp maybe_apply(_changeset, fun) when is_function(fun, 0), do: fun.()
  defp maybe_apply(changeset, fun) when is_function(fun, 1), do: fun.(changeset)
  defp maybe_apply(_changeset, value), do: value

  def trim_change(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
    update_change(changeset, field, fn
      nil -> nil
      changes when is_list(changes) -> Enum.map(changes, &safe_trim/1)
      change when is_binary(change) -> String.trim(change)
      change -> change
    end)
  end

  def trim_change(%Ecto.Changeset{} = changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      trim_change(changeset, field)
    end)
  end

  def trim_change(%Ecto.Changeset{} = changeset, _field), do: changeset

  # Validations

  def validate_list(
        %Ecto.Changeset{} = changeset,
        field,
        element_type,
        fun \\ fn changeset, _field -> changeset end
      ) do
    validate_change(changeset, field, fn _current_field, value ->
      cond do
        not is_list(value) ->
          [{field, "must be a list"}]

        Enum.empty?(value) ->
          []

        true ->
          value
          |> Enum.with_index()
          |> Enum.flat_map(&validate_list_element(field, fun, element_type, &1))
      end
    end)
  end

  defp validate_list_element(field, fun, element_type, {value, index}) do
    {%{}, %{value: element_type}}
    |> Ecto.Changeset.cast(%{value: value}, [:value])
    |> fun.(:value)
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, _} ->
        []

      {:error, %{errors: errors}} ->
        {error, meta} = errors[:value]
        [{field, {error, meta ++ [validated_as: :list, at: index]}}]
    end
  end

  # idna reports a disallowed character with an exit, not an exception.
  def try_encode_domain(domain) do
    charlist = String.to_charlist(domain)

    try do
      {:ok, :idna.encode(charlist, [{:uts46, true}]) |> to_string()}
    catch
      _kind, _reason -> :error
    end
  end

  def validate_uri(%Ecto.Changeset{} = changeset, field, opts \\ []) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      case URI.new(value) do
        {:ok, %URI{} = uri} -> validate_uri_errors(field, uri, opts)
        {:error, _part} -> [{field, "is invalid"}]
      end
    end)
  end

  defp validate_uri_errors(field, uri, opts) do
    valid_schemes = Keyword.get(opts, :schemes, ~w[http https])
    require_trailing_slash? = Keyword.get(opts, :require_trailing_slash, false)
    block_private_ips? = Keyword.get(opts, :block_private_ips, false)

    cond do
      uri.host == nil or uri.host == "" ->
        [{field, "does not contain a scheme or a host"}]

      uri.scheme == nil ->
        [{field, "does not contain a scheme"}]

      uri.scheme not in valid_schemes ->
        [{field, "only #{Enum.join(valid_schemes, ", ")} schemes are supported"}]

      require_trailing_slash? and not is_nil(uri.path) and
          not String.ends_with?(uri.path, "/") ->
        [{field, "does not end with a trailing slash"}]

      block_private_ips? and not public_host?(uri.host) ->
        [{field, "must not be a private or reserved IP address"}]

      true ->
        []
    end
  end

  def public_host?(host) when is_binary(host) and host != "" do
    not private_host?(host)
  end

  def public_host?(_), do: false

  def validate_public_host(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      if public_host?(value) do
        []
      else
        [{field, "must not be a private or reserved IP address"}]
      end
    end)
  end

  defp private_host?(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        private_ip?(ip)

      {:error, _} ->
        ips4 =
          case :inet.getaddrs(charlist, :inet) do
            {:ok, ips} -> ips
            _ -> []
          end

        ips6 =
          case :inet.getaddrs(charlist, :inet6) do
            {:ok, ips} -> ips
            _ -> []
          end

        Enum.any?(ips4 ++ ips6, &private_ip?/1)
    end
  end

  # IPv4-mapped IPv6 addresses (::ffff:w.x.y.z)
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _} = ip), do: private_ip?(Portal.Types.IP.unmap(ip))
  def private_ip?({_, _, _, _} = ip), do: private_ip_in_cidrs?(ip, @special_use_ipv4_cidrs)

  def private_ip?({_, _, _, _, _, _, _, _} = ip),
    do: private_ip_in_cidrs?(ip, @special_use_ipv6_cidrs)

  def private_ip?(_), do: false

  defp private_ip_in_cidrs?(ip, cidrs) do
    inet = %Postgrex.INET{address: ip}
    Enum.any?(cidrs, &Portal.Types.CIDR.contains?(&1, inet))
  end

  @email_regex ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/
  @email_max_length 160

  def valid_email?(value) when is_binary(value),
    do: String.length(value) <= @email_max_length and Regex.match?(@email_regex, value)

  def valid_email?(_), do: false

  def validate_email(%Ecto.Changeset{} = changeset, field, opts \\ []) do
    message = Keyword.get(opts, :message, "is an invalid email address")

    changeset
    |> validate_format(field, @email_regex, message: message)
    |> validate_length(field, max: @email_max_length)
  end

  def normalize_url(%Ecto.Changeset{} = changeset, field) do
    with {:ok, value} <- fetch_change(changeset, field),
         false <- has_errors?(changeset, field) do
      uri = URI.parse(value)
      scheme = uri.scheme || "https"
      port = uri.port || URI.default_port(scheme)
      path = maybe_add_trailing_slash(uri.path || "/")
      uri = %{uri | scheme: scheme, port: port, path: path}
      uri_string = URI.to_string(uri)
      put_change(changeset, field, uri_string)
    else
      _ -> changeset
    end
  end

  defp maybe_add_trailing_slash(value) do
    if String.ends_with?(value, "/") do
      value
    else
      value <> "/"
    end
  end

  def validate_not_in_cidr(%Ecto.Changeset{} = changeset, ip_or_cidr_field, cidr, opts \\ []) do
    validate_change(changeset, ip_or_cidr_field, fn _ip_or_cidr_field, ip_or_cidr ->
      case Portal.Types.INET.cast(ip_or_cidr) do
        {:ok, ip_or_cidr} ->
          cidr_overlap_error(ip_or_cidr_field, ip_or_cidr, cidr, opts)

        _other ->
          []
      end
    end)
  end

  defp cidr_overlap_error(field, ip_or_cidr, cidr, opts) do
    if Portal.Types.CIDR.contains?(cidr, ip_or_cidr) or
         Portal.Types.CIDR.contains?(ip_or_cidr, cidr) do
      [{field, Keyword.get(opts, :message, "cannot be in the CIDR #{cidr}")}]
    else
      []
    end
  end

  def validate_and_normalize_cidr(%Ecto.Changeset{} = changeset, field, _opts \\ []) do
    with {_data_or_changes, value} <- fetch_change(changeset, field),
         {:ok, cidr} <- Portal.Types.CIDR.cast(value) do
      {range_start, _range_end} = Portal.Types.CIDR.range(cidr)
      cidr = %{cidr | address: range_start}
      put_change(changeset, field, to_string(cidr))
    else
      :error ->
        changeset

      {:error, _reason} ->
        add_error(changeset, field, "is not a valid CIDR range")
    end
  end

  def validate_and_normalize_ip(%Ecto.Changeset{} = changeset, field, _opts \\ []) do
    with {_data_or_changes, value} <- fetch_change(changeset, field),
         {:ok, ip} <- Portal.Types.IP.cast(value) do
      put_change(changeset, field, to_string(ip))
    else
      :error ->
        changeset

      {:error, _reason} ->
        add_error(changeset, field, "is not a valid IP address")
    end
  end

  def validate_base64(%Ecto.Changeset{} = changeset, field) do
    validate_change(changeset, field, fn _cur, value ->
      case Base.decode64(value) do
        :error -> [{field, "must be a base64-encoded string"}]
        {:ok, _decoded} -> []
      end
    end)
  end

  def validate_datetime(%Ecto.Changeset{} = changeset, field, greater_than: greater_than) do
    validate_change(changeset, field, fn _current_field, value ->
      if DateTime.compare(value, greater_than) == :gt do
        []
      else
        [{field, "must be greater than #{inspect(greater_than)}"}]
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

  def errors_to_string(%Ecto.Changeset{} = changeset, fields \\ :all) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    # Filter only requested fields (unless :all)
    filtered_errors =
      case fields do
        :all -> errors
        _ when is_list(fields) -> Map.take(errors, fields)
      end

    # Join all messages into a single string
    Enum.map_join(filtered_errors, "\n", fn {field, messages} ->
      "#{field}: #{Enum.join(messages, "; ")}"
    end)
  end

  defp safe_trim(term) when is_binary(term), do: String.trim(term)
  defp safe_trim(term), do: term
end
