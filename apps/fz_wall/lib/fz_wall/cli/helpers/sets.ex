defmodule FzWall.CLI.Helpers.Sets do
  @moduledoc """
  Helper module concering nft's named sets
  """

  @actions [:drop, :accept]
  @ip_types [:ip, :ip6]

  def list_filter_sets(user_id) do
    Enum.flat_map(
      [true, false],
      fn layer4 ->
        cross(@ip_types, @actions)
        |> Enum.map(fn {ip_type, action} ->
          %{
            name: get_filter_set_name(user_id, ip_type, action, layer4),
            ip_type: ip_type,
            action: action,
            layer4: layer4
          }
        end)
      end
    )
  end

  def list_dev_sets(user_id) do
    Enum.map(@ip_types, fn type -> %{name: get_device_set_name(user_id, type), ip_type: type} end)
  end

  def get_ip_types do
    @ip_types
  end

  def get_actions do
    @actions
  end

  def get_device_set_name(user_id, type), do: "user#{user_id}_#{type}_devices"
  def get_user_chain(nil), do: "forward"
  def get_user_chain(user_id), do: "user#{user_id}"

  def get_filter_set_name(nil, ip_type, action, false),
    do: "#{ip_type}_#{action}"

  def get_filter_set_name(user_id, ip_type, action, false),
    do: "user#{user_id}_#{ip_type}_#{action}"

  def get_filter_set_name(nil, ip_type, action, true),
    do: "#{ip_type}_#{action}_layer4"

  def get_filter_set_name(user_id, ip_type, action, true),
    do: "user#{user_id}_#{ip_type}_#{action}_layer4"

  def cross([x | a], [y | b]) do
    [{x, y}] ++ cross([x], b) ++ cross(a, [y | b])
  end

  def cross([], _b), do: []
  def cross(_a, []), do: []
end
