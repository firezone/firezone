defmodule Portal.Policies.Postures.Evaluator do
  @moduledoc """
  Decides whether a device satisfies a policy's postures.

  Every provider tree must pass. A tree runs against the rows the device
  matched for that provider, `firezone` against the device itself. A NULL
  field fails every operator except `does_not_exist`, and a provider with no
  rows runs its tree once against an empty row, so nothing passes by absence.

  The result carries the earliest moment a passing `within_last` leaf stops
  holding, which the caller folds into the authorization's expiry.
  """

  alias Portal.Device
  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.{And, Leaf, Not, Or, Provider}

  @type violation :: {:postures, atom()}

  @spec evaluate(Postures.t() | nil, Device.t(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, [violation()]}
  def evaluate(nil, %Device{}, %DateTime{}), do: {:ok, nil}

  def evaluate(%Postures{providers: providers}, %Device{type: :client} = device, %DateTime{} = now) do
    providers
    |> Enum.sort_by(fn {provider, _entry} -> provider_rank(provider) end)
    |> Enum.reduce({[], nil}, fn {provider, entry}, {violated, expires_at} ->
      case evaluate_provider(provider, entry, device, now) do
        {true, provider_expires_at} -> {violated, earliest(expires_at, provider_expires_at)}
        {false, _expires_at} -> {[{:postures, provider} | violated], expires_at}
      end
    end)
    |> case do
      {[], expires_at} -> {:ok, expires_at}
      {violated, _expires_at} -> {:error, Enum.reverse(violated)}
    end
  end

  defp evaluate_provider(:firezone, %Provider{expr: expr}, device, now) do
    evaluate_node(expr, device, device, now)
  end

  defp evaluate_provider(provider, %Provider{rows: mode, expr: expr}, device, now) do
    case Map.get(device.posture, provider, []) do
      [] -> evaluate_node(expr, nil, device, now)
      rows -> evaluate_rows(mode, rows, expr, device, now)
    end
  end

  defp evaluate_rows(:any, rows, expr, device, now) do
    rows
    |> Enum.map(&evaluate_node(expr, &1, device, now))
    |> any_pass()
  end

  defp evaluate_rows(:all, rows, expr, device, now) do
    rows
    |> Enum.map(&evaluate_node(expr, &1, device, now))
    |> all_pass()
  end

  defp evaluate_node(%And{nodes: nodes}, row, device, now) do
    nodes |> Enum.map(&evaluate_node(&1, row, device, now)) |> all_pass()
  end

  defp evaluate_node(%Or{nodes: nodes}, row, device, now) do
    nodes |> Enum.map(&evaluate_node(&1, row, device, now)) |> any_pass()
  end

  defp evaluate_node(%Not{node: node}, row, device, now) do
    {passed?, _expires_at} = evaluate_node(node, row, device, now)
    {not passed?, nil}
  end

  defp evaluate_node(%Leaf{} = leaf, row, device, now) do
    value = field_value(leaf.field, row, device)
    evaluate_leaf(leaf, value, now)
  end

  # Everything must hold, so the result holds until the first child stops holding.
  defp all_pass(results) do
    if Enum.all?(results, &elem(&1, 0)) do
      {true, results |> Enum.map(&elem(&1, 1)) |> Enum.reduce(nil, &earliest/2)}
    else
      {false, nil}
    end
  end

  # One holding child is enough, so the result holds as long as the longest
  # lived one, and forever when any passing child has no expiry.
  defp any_pass(results) do
    case Enum.filter(results, &elem(&1, 0)) do
      [] -> {false, nil}
      passing -> {true, passing |> Enum.map(&elem(&1, 1)) |> latest_or_forever()}
    end
  end

  defp latest_or_forever(expiries) do
    if Enum.any?(expiries, &is_nil/1) do
      nil
    else
      Enum.max(expiries, DateTime)
    end
  end

  defp earliest(nil, other), do: other
  defp earliest(other, nil), do: other
  defp earliest(left, right), do: Enum.min([left, right], DateTime)

  defp field_value(:enrolled, row, _device), do: not is_nil(row)
  defp field_value(:attested, _row, device), do: device.attested?
  defp field_value(_field, nil, _device), do: nil
  defp field_value(field, row, _device), do: Map.get(row, field)

  defp evaluate_leaf(%Leaf{op: :exists}, value, _now), do: {not is_nil(value), nil}
  defp evaluate_leaf(%Leaf{op: :does_not_exist}, value, _now), do: {is_nil(value), nil}
  defp evaluate_leaf(%Leaf{}, nil, _now), do: {false, nil}

  defp evaluate_leaf(%Leaf{type: type, op: op, parsed: parsed}, value, now) do
    compare(type, op, value, parsed, now)
  end

  defp compare(type, op, value, parsed, _now) when type in [:string, :enum_string] do
    value = String.downcase(value)

    passed? =
      case op do
        :is -> value == parsed
        :is_not -> value != parsed
        :is_in -> value in parsed
        :is_not_in -> value not in parsed
        :contains -> String.contains?(value, parsed)
        :does_not_contain -> not String.contains?(value, parsed)
        :starts_with -> String.starts_with?(value, parsed)
        :ends_with -> String.ends_with?(value, parsed)
        :matches -> Postures.safe_match?(parsed, value)
        :does_not_match -> not Postures.safe_match?(parsed, value)
      end

    {passed?, nil}
  end

  defp compare(:boolean, :is, value, parsed, _now), do: {value == parsed, nil}

  defp compare(type, op, value, parsed, _now) when type in [:integer, :float] do
    passed? =
      case op do
        :eq -> value == parsed
        :ne -> value != parsed
        :gt -> value > parsed
        :gte -> value >= parsed
        :lt -> value < parsed
        :lte -> value <= parsed
      end

    {passed?, nil}
  end

  defp compare(:version, op, value, parsed, _now) do
    case Postures.parse_version(value) do
      [] ->
        {false, nil}

      segments ->
        comparison = Postures.compare_versions(segments, parsed)

        passed? =
          case op do
            :is -> comparison == :eq
            :is_not -> comparison != :eq
            :gt -> comparison == :gt
            :gte -> comparison != :lt
            :lt -> comparison == :lt
            :lte -> comparison != :gt
          end

        {passed?, nil}
    end
  end

  defp compare(:datetime, op, %DateTime{} = value, parsed, now), do: compare_moment(op, value, parsed, now)

  defp compare(:date, op, %Date{} = value, %Date{} = parsed, _now) do
    passed? =
      case op do
        :before -> Date.compare(value, parsed) == :lt
        :after -> Date.compare(value, parsed) == :gt
      end

    {passed?, nil}
  end

  defp compare(:date, op, %Date{} = value, %Duration{} = parsed, now) do
    compare_moment(op, DateTime.new!(value, ~T[00:00:00]), parsed, now)
  end

  defp compare(:ip, op, %Postgrex.INET{} = value, cidrs, _now) do
    address = %Postgrex.INET{address: value.address, netmask: nil}
    inside? = Enum.any?(cidrs, &Portal.Types.CIDR.contains?(&1, address))

    case op do
      :is_in_cidr -> {inside?, nil}
      :is_not_in_cidr -> {not inside?, nil}
    end
  end

  defp compare(:string_array, op, value, parsed, _now) when is_list(value) do
    value = Enum.map(value, &String.downcase/1)

    passed? =
      case op do
        :contains -> parsed in value
        :does_not_contain -> parsed not in value
        :contains_any_of -> Enum.any?(parsed, &(&1 in value))
        :contains_all_of -> Enum.all?(parsed, &(&1 in value))
        :is_empty -> value == []
        :is_not_empty -> value != []
      end

    {passed?, nil}
  end

  defp compare(:json, op, value, _parsed, _now) do
    empty? = value in [%{}, []]

    case op do
      :is_empty -> {empty?, nil}
      :is_not_empty -> {not empty?, nil}
    end
  end

  defp compare_moment(:before, value, %DateTime{} = parsed, _now) do
    {DateTime.compare(value, parsed) == :lt, nil}
  end

  defp compare_moment(:after, value, %DateTime{} = parsed, _now) do
    {DateTime.compare(value, parsed) == :gt, nil}
  end

  defp compare_moment(:within_last, value, %Duration{} = duration, now) do
    cutoff = DateTime.shift(now, Duration.negate(duration))

    if DateTime.compare(value, cutoff) == :lt do
      {false, nil}
    else
      {true, DateTime.shift(value, duration)}
    end
  end

  defp compare_moment(:not_within_last, value, %Duration{} = duration, now) do
    cutoff = DateTime.shift(now, Duration.negate(duration))
    {DateTime.compare(value, cutoff) == :lt, nil}
  end

  defp provider_rank(provider) do
    Enum.find_index(Portal.Policies.Postures.Fields.providers(), &(&1 == provider))
  end
end
