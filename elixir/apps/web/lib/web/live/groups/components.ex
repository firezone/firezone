defmodule Web.Groups.Components do
  use Web, :component_library
  alias Domain.Actors

  def select_options(groups) do
    groups
    |> Enum.group_by(&options_index_and_label/1)
    |> Enum.sort_by(fn {{priority, label}, _groups} ->
      {priority, label}
    end)
    |> Enum.map(fn {{_priority, label}, groups} ->
      options = groups |> Enum.sort_by(& &1.name) |> Enum.map(&group_option/1)
      {label, options}
    end)
  end

  defp options_index_and_label(group) do
    index =
      cond do
        Actors.group_synced?(group) -> 9
        Actors.group_managed?(group) -> 1
        true -> 2
      end

    label =
      cond do
        Actors.group_synced?(group) -> group.provider.name
        Actors.group_managed?(group) -> nil
        true -> nil
      end

    {index, label}
  end

  defp group_option(group) do
    [key: group.name, value: group.id]
  end
end
