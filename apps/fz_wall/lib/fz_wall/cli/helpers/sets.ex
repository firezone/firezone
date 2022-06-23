defmodule FzWall.CLI.Helpers.Sets do
  @moduledoc """
  Helper module concering nft's named sets
  """

  @actions [:drop, :accept]
  @types [:ip, :ip6]

  def list_dest_sets(user_id) do
    cross(@types, @actions)
    |> Enum.map(fn {type, action} ->
      %{name: get_dest_set_name(user_id, type, action), type: type}
    end)
  end

  def list_sets(nil), do: list_dest_sets(nil)

  def list_sets(user_id) do
    list_dest_sets(user_id) ++
      (@types |> Enum.map(fn type -> %{name: get_device_set_name(user_id, type), type: type} end))
  end

  def get_types do
    @types
  end

  def get_actions do
    @actions
  end

  def get_dest_set_name(nil, type, action), do: "#{type}_#{action}"
  def get_dest_set_name(user_id, type, action), do: "user_#{user_id}_#{type}_#{action}"
  def get_device_set_name(nil, _type), do: nil
  def get_device_set_name(user_id, type), do: "user_#{user_id}_#{type}_devices"

  def cross([x | a], [y | b]) do
    [{x, y}] ++ cross([x], b) ++ cross(a, [y | b])
  end

  def cross([], _b), do: []
  def cross(_a, []), do: []
end
