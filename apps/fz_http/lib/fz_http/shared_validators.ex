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

  def validate_no_duplicates(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      trimmed = Enum.map(String.split(value, ","), fn el -> String.trim(el) end)
      dupes = Enum.uniq(trimmed -- Enum.uniq(trimmed))

      case dupes do
        [] ->
          []

        dupes ->
          [
            {field,
             "is invalid: duplicate DNS servers are not allowed: #{Enum.join(dupes, ", ")}"}
          ]
      end
    end)
  end

  def validate_fqdn_or_ip(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(not (valid_ip?(&1) or valid_fqdn?(&1))))
      |> then(fn invalid ->
        if invalid do
          [{field, "is invalid: #{invalid} is not a valid FQDN or IPv4 / IPv6 address"}]
        else
          []
        end
      end)
    end)
  end

  def validate_list_of_ips(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(not valid_ip?(&1)))
      |> then(fn invalid ->
        if invalid do
          [{field, "is invalid: #{invalid} is not a valid IPv4 / IPv6 address"}]
        else
          []
        end
      end)
    end)
  end

  def validate_list_of_ips_or_cidrs(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.find(&(not (valid_ip?(&1) or valid_cidr?(&1))))
      |> then(fn invalid ->
        if invalid do
          [{field, "is invalid: #{invalid} is not a valid IPv4 / IPv6 address or CIDR range"}]
        else
          []
        end
      end)
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
end
