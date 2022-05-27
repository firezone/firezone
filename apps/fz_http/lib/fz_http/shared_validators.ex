defmodule FzHttp.SharedValidators do
  @moduledoc """
  Shared validators to use between schemas.
  """

  import Ecto.Changeset

  import FzCommon.FzNet,
    only: [
      valid_ip?: 1,
      valid_fqdn?: 1,
      valid_cidr?: 1
    ]

  @mtu_min 576
  @mtu_max 1_420

  def validate_cidr_inclusion(changeset, cidr_field, addr_field)
      when is_atom(cidr_field) and is_atom(addr_field) do
    cidr_value = get_field(changeset, cidr_field)
    addr_value = get_field(changeset, addr_field)

    if is_struct(cidr_value) && is_struct(addr_value) do
      if FzCommon.FzNet.cidr_contains?(decode(cidr_value), decode(addr_value)) do
        changeset
      else
        add_error(changeset, addr_field, "must be contained within the network #{cidr_value}")
      end
    else
      changeset
    end
  end

  def validate_ip_pair_existence(changeset, field_tuples) when is_list(field_tuples) do
    if field_tuples
       |> Enum.all?(fn {net, addr} ->
         is_nil(get_field(changeset, net)) || is_nil(get_field(changeset, addr))
       end) do
      add_error(
        changeset,
        :ipv4_address,
        "is invalid",
        additional_info:
          "Must specify a valid IPv4 address and network or IPv6 address and network."
      )
    else
      changeset
    end
  end

  def validate_mtu(changeset, field) when is_atom(field) do
    validate_number(
      changeset,
      field,
      greater_than_or_equal_to: @mtu_min,
      less_than_or_equal_to: @mtu_max
    )
  end

  def validate_no_duplicates(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      values = split_comma_list(value)
      dupes = Enum.uniq(values -- Enum.uniq(values))

      error_if(
        dupes,
        &(&1 != []),
        &{field, "is invalid: duplicate DNS servers are not allowed: #{Enum.join(&1, ", ")}"}
      )
    end)
  end

  def validate_fqdn_or_ip(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> split_comma_list()
      |> Enum.find(&(not (valid_ip?(&1) or valid_fqdn?(&1))))
      |> error_if(
        &(!is_nil(&1)),
        &{field, "is invalid: #{&1} is not a valid FQDN or IPv4 / IPv6 address"}
      )
    end)
  end

  def validate_list_of_ips(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> split_comma_list()
      |> Enum.find(&(not valid_ip?(&1)))
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
      |> Enum.find(&(not (valid_ip?(&1) or valid_cidr?(&1))))
      |> error_if(
        &(!is_nil(&1)),
        &{field, "is invalid: #{&1} is not a valid IPv4 / IPv6 address or CIDR range"}
      )
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

  defp decode(%Postgrex.INET{} = inet) do
    EctoNetwork.INET.decode(inet)
  end
end
