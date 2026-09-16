defmodule Portal.Policies.Postures.Evaluator do
  @moduledoc """
  Decides whether a device satisfies a policy's postures.

  A leaf runs against the rows the device matched for its provider, and a
  `firezone` leaf against the device itself. A leaf holds when any row holds,
  or when every row holds for `rows: all`. A NULL field fails every operator
  except `does_not_exist`, and a leaf whose provider matched no rows runs
  once against an empty row, so nothing passes by absence.

  The result carries the earliest moment a passing `within_last` leaf stops
  holding, which the caller folds into the authorization's expiry.
  """

  alias Portal.Device
  alias Portal.Policies.Postures
  alias Portal.Policies.Postures.{And, Fields, Leaf, Not, Or}

  @spec evaluate(Postures.t() | nil, Device.t(), DateTime.t()) ::
          {:ok, DateTime.t() | nil} | {:error, [:postures]}
  def evaluate(nil, %Device{}, %DateTime{}), do: {:ok, nil}

  def evaluate(%Postures{expr: expr}, %Device{type: :client} = device, %DateTime{} = now) do
    case prune(expr, platform(device)) do
      nil ->
        {:ok, nil}

      expr ->
        case evaluate_node(expr, device, now) do
          {true, expires_at} -> {:ok, expires_at}
          {false, _expires_at} -> {:error, [:postures]}
        end
    end
  end

  @doc """
  The platform the device runs, from the matched provider rows first, since
  an MDM's word beats the Client's own, and the user agent otherwise. `nil`
  when nothing says.
  """
  @spec platform(Device.t()) :: atom() | nil
  def platform(%Device{} = device) do
    row_platform =
      Enum.find_value(~w[intune iru defender santa sentinelone]a, fn provider ->
        device.posture |> Map.get(provider, []) |> Enum.find_value(&row_platform/1)
      end)

    row_platform || user_agent_platform(device.last_seen_user_agent)
  end

  # Rules on fields that say nothing about this platform are dropped, so a
  # requirement about jailbreaks does not fail a Windows laptop. A branch
  # with nothing left holds. Without a known platform nothing is dropped.
  defp prune(expr, nil), do: expr

  defp prune(%Leaf{provider: provider, field: field} = leaf, platform) do
    if platform in Fields.platforms(provider, field), do: leaf, else: nil
  end

  defp prune(%And{nodes: nodes}, platform), do: prune_nodes(nodes, platform, &%And{nodes: &1})
  defp prune(%Or{nodes: nodes}, platform), do: prune_nodes(nodes, platform, &%Or{nodes: &1})

  defp prune(%Not{node: node}, platform) do
    case prune(node, platform) do
      nil -> nil
      node -> %Not{node: node}
    end
  end

  defp prune_nodes(nodes, platform, build) do
    case nodes |> Enum.map(&prune(&1, platform)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      kept -> build.(kept)
    end
  end

  defp row_platform(%Portal.Intune.Device{operating_system: os}), do: os_name_platform(os)
  defp row_platform(%Portal.Iru.Device{os_name: os}), do: os_name_platform(os)
  defp row_platform(%Portal.Defender.Device{os_platform: os}), do: os_name_platform(os)
  defp row_platform(%Portal.SentinelOne.Device{os_type: os}), do: os_name_platform(os)
  defp row_platform(%Portal.Santa.Device{}), do: :macos
  defp row_platform(_row), do: nil

  # Intune says "Windows", Defender "Windows10" or "WindowsServer2022", so a
  # prefix is what is shared.
  defp os_name_platform(nil), do: nil

  defp os_name_platform(name) do
    case String.downcase(name) do
      "windows" <> _rest -> :windows
      "macos" <> _rest -> :macos
      "mac os" <> _rest -> :macos
      "ipados" <> _rest -> :ios
      "ios" <> _rest -> :ios
      "android" <> _rest -> :android
      "linux" <> _rest -> :linux
      _other -> nil
    end
  end

  defp user_agent_platform(nil), do: nil
  defp user_agent_platform("Windows/" <> _rest), do: :windows
  defp user_agent_platform("Mac OS/" <> _rest), do: :macos
  defp user_agent_platform("iOS/" <> _rest), do: :ios
  defp user_agent_platform("Android/" <> _rest), do: :android

  defp user_agent_platform(user_agent) do
    if String.contains?(user_agent, ["headless-client/", "gui-client/"]), do: :linux, else: nil
  end

  defp evaluate_node(%And{nodes: nodes}, device, now) do
    nodes |> Enum.map(&evaluate_node(&1, device, now)) |> all_pass()
  end

  defp evaluate_node(%Or{nodes: nodes}, device, now) do
    nodes |> Enum.map(&evaluate_node(&1, device, now)) |> any_pass()
  end

  defp evaluate_node(%Not{node: node}, device, now) do
    {passed?, _expires_at} = evaluate_node(node, device, now)
    {not passed?, nil}
  end

  defp evaluate_node(%Leaf{provider: :firezone} = leaf, device, now) do
    leaf
    |> resolve_macro(device)
    |> evaluate_leaf(field_value(leaf.field, device, device), now)
  end

  defp evaluate_node(%Leaf{provider: provider, rows: rows} = leaf, device, now) do
    results =
      device
      |> matched_rows(provider)
      |> Enum.map(&evaluate_leaf(leaf, field_value(leaf.field, &1, device), now))

    case rows do
      :any -> any_pass(results)
      :all -> all_pass(results)
    end
  end

  # No rows still runs the leaf once, against nothing, so absence cannot pass.
  defp matched_rows(device, provider) do
    case Map.get(device.posture, provider, []) do
      [] -> [nil]
      rows -> rows
    end
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

  defp resolve_macro(%Leaf{parsed: :latest} = leaf, device) do
    %{leaf | parsed: Postures.parse_version(Portal.ComponentVersions.client_version(device))}
  end

  defp resolve_macro(leaf, _device), do: leaf

  defp field_value(:enrolled, row, _device), do: not is_nil(row)
  defp field_value(:os_up_to_date, nil, _device), do: nil
  defp field_value(:os_up_to_date, row, _device), do: Portal.OSReleases.row_up_to_date?(row)
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

  # A date column is the start of that day.
  defp compare(:datetime, op, %Date{} = value, parsed, now) do
    compare_moment(op, DateTime.new!(value, ~T[00:00:00]), parsed, now)
  end

  defp compare(type, op, %Postgrex.INET{} = value, cidrs, _now) when type in [:ip, :ipv4, :ipv6] do
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
end
