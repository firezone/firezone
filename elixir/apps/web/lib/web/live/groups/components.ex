defmodule Web.Groups.Components do
  use Web, :component_library
  alias Domain.Actors

  def fetch_group_option(id, subject) do
    {:ok, group} = Actors.fetch_group_by_id(id, subject)
    {:ok, group_option(group)}
  end

  def list_group_options(search_query_or_nil, subject) do
    filter =
      if search_query_or_nil != "" and search_query_or_nil != nil,
        do: [name: search_query_or_nil],
        else: []

    {:ok, groups, metadata} =
      Actors.list_groups(subject, preload: :provider, limit: 25, filter: filter)

    {:ok, grouped_select_options(groups), metadata}
  end

  defp grouped_select_options(groups) do
    groups
    |> Enum.group_by(&option_groups_index_and_label/1)
    |> Enum.sort_by(fn {{options_group_index, options_group_label}, _groups} ->
      {options_group_index, options_group_label}
    end)
    |> Enum.map(fn {{_options_group_index, options_group_label}, groups} ->
      {options_group_label, groups |> Enum.sort_by(& &1.name) |> Enum.map(&group_option/1)}
    end)
  end

  defp option_groups_index_and_label(group) do
    index =
      cond do
        Actors.group_synced?(group) -> 9
        Actors.group_managed?(group) -> 1
        true -> 2
      end

    label =
      cond do
        Actors.group_synced?(group) -> "Synced from #{group.provider.name}"
        Actors.group_managed?(group) -> "Managed by Firezone"
        true -> "Manually managed"
      end

    {index, label}
  end

  defp group_option(group) do
    {group.id, group.name, group}
  end
end
