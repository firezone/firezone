defmodule FzWall.CLI.Helpers.Sets do
  @moduledoc """
  Helper module concering nft's named sets
  """

  @actions [:drop, :accept]
  @ip_types [:ip, :ip6]

  defp port_rules_supported?, do: Application.fetch_env!(:fz_wall, :port_based_rules_supported)

  def list_filter_sets(user_id) do
    get_all_filter_sets(user_id, port_rules_supported?())
  end

  defp get_all_filter_sets(user_id, false) do
    get_filter_sets_spec(user_id, false)
  end

  defp get_all_filter_sets(user_id, true) do
    get_all_filter_sets(user_id, false) ++ get_filter_sets_spec(user_id, true)
  end

  defp get_filter_sets_spec(user_id, layer4) do
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

  defp cross([x | a], [y | b]) do
    [{x, y}] ++ cross([x], b) ++ cross(a, [y | b])
  end

  defp cross([], _b), do: []
  defp cross(_a, []), do: []
end
