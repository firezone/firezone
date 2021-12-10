defmodule FzHttp.SharedValidators do
  @moduledoc """
  Shared validators to use between schemas.
  """

  import Ecto.Changeset

  import FzCommon.FzNet,
    only: [
      valid_ip?: 1,
      valid_cidr?: 1
    ]

  def validate_no_duplicates(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        trimmed = Enum.map(String.split(value, ","), fn el -> String.trim(el) end)
        dupes = Enum.uniq(trimmed -- Enum.uniq(trimmed))

        if length(dupes) > 0 do
          throw(dupes)
        end

        []
      catch
        dupes ->
          [
            {field,
             "is invalid: duplicate DNS servers are not allowed: #{Enum.join(dupes, ", ")}"}
          ]
      end
    end)
  end

  def validate_ip(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        for ip <- String.split(value, ",") do
          unless valid_ip?(String.trim(ip)) do
            throw(ip)
          end
        end

        []
      catch
        ip ->
          [{field, "is invalid: #{String.trim(ip)} is not a valid IPv4 / IPv6 address"}]
      end
    end)
  end

  def validate_list_of_ips(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        for ip <- String.split(value, ",") do
          unless valid_ip?(String.trim(ip)) do
            throw(ip)
          end
        end

        []
      catch
        ip ->
          [{field, "is invalid: #{String.trim(ip)} is not a valid IPv4 / IPv6 address"}]
      end
    end)
  end

  def validate_list_of_ips_or_cidrs(changeset, field) when is_atom(field) do
    validate_change(changeset, field, fn _current_field, value ->
      try do
        for ip_or_cidr <- String.split(value, ",") do
          trimmed_ip_or_cidr = String.trim(ip_or_cidr)

          unless valid_ip?(trimmed_ip_or_cidr) or valid_cidr?(trimmed_ip_or_cidr) do
            throw(ip_or_cidr)
          end
        end

        []
      catch
        ip_or_cidr ->
          [
            {field,
             """
             is invalid: #{String.trim(ip_or_cidr)} is not a valid IPv4 / IPv6 address or \
             CIDR range\
             """}
          ]
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
end
