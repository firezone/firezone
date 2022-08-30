defmodule FzHttp.SharedValidators do
  @moduledoc """
  Shared validators to use between schemas.
  """

  import Ecto.Changeset

  import FzCommon.FzNet,
    only: [
      valid_ip?: 1,
      valid_fqdn?: 1,
      valid_hostname?: 1,
      valid_cidr?: 1
    ]

  defp do_trim(nil), do: nil

  defp do_trim(str) when is_binary(str), do: String.trim(str)

  def trim(changeset, field) when is_atom(field) do
    trim(changeset, [field])
  end

  def trim(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, cs ->
      update_change(cs, field, &do_trim/1)
    end)
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
      |> Enum.find(&(not (valid_ip?(&1) or valid_fqdn?(&1) or valid_hostname?(&1))))
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
end
