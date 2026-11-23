defmodule PortalWeb.Access.Components do
  @moduledoc """
  Pieces shared by the Access pages and the policies list.
  """
  use PortalWeb, :component_library

  @doc """
  How a direct-access group reads in a list: the names of a few people, or a count.
  """
  @spec people_label([String.t()]) :: String.t()
  def people_label([]), do: "No people"
  def people_label(names) when length(names) <= 3, do: "People: " <> Enum.join(names, ", ")
  def people_label(names), do: people_count(length(names))

  @doc "The names of the people in each direct-access group, keyed by group id."
  def direct_people(group_ids, subject), do: __MODULE__.Database.direct_people(group_ids, subject)

  @spec people_count(non_neg_integer()) :: String.t()
  def people_count(1), do: "1 person"
  def people_count(count), do: "#{count} people"

  @doc "An outlined chip, a link when `navigate` is given."
  attr :navigate, :string, default: nil
  attr :icon, :string, default: nil
  attr :dashed, :boolean, default: false
  attr :muted, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def chip(%{navigate: nil} = assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 border px-2 py-px text-xs whitespace-nowrap",
        if(@dashed, do: "border-dashed", else: "border-solid"),
        if(@muted, do: "border-hair text-muted", else: "border-rule text-fg"),
        @class
      ]}
      {@rest}
    >
      <Core.icon :if={@icon} name={@icon} class="w-3 h-3 text-muted" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  def chip(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "group/chip inline-flex items-center gap-1 border px-2 py-px text-xs whitespace-nowrap",
        "hover:bg-fg hover:text-bg hover:border-fg",
        if(@dashed, do: "border-dashed", else: "border-solid"),
        if(@muted, do: "border-hair text-muted", else: "border-rule text-fg"),
        @class
      ]}
      {@rest}
    >
      <Core.icon :if={@icon} name={@icon} class="w-3 h-3 text-muted group-hover/chip:text-bg" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc "The search box above a table that is not a `LiveTable`."
  attr :id, :string, required: true
  attr :value, :string, default: ""
  attr :placeholder, :string, required: true
  attr :event, :string, default: "search"

  def search_box(assigns) do
    ~H"""
    <form id={@id} phx-change={@event} phx-submit={@event} class="relative w-full max-w-sm">
      <Core.icon
        name="ri-search-line"
        class="absolute left-2.5 top-1/2 -translate-y-1/2 w-4 h-4 text-muted pointer-events-none"
      />
      <input
        type="search"
        name="search"
        value={@value}
        placeholder={@placeholder}
        phx-debounce="300"
        autocomplete="off"
        class="w-full pl-8 pr-3 py-1.5 text-sm bg-bg text-fg border border-rule placeholder:text-faint focus:border-fg focus:ring-0"
      />
    </form>
    """
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    @doc "The names of the people in each direct-access group, keyed by group id."
    def direct_people([], _subject), do: %{}

    def direct_people(group_ids, subject) do
      from(m in Portal.Membership,
        join: a in Portal.Actor,
        on: a.id == m.actor_id and a.account_id == m.account_id,
        join: g in Portal.Group,
        on: g.id == m.group_id and g.account_id == m.account_id,
        where: m.group_id in ^group_ids and not is_nil(g.resource_id),
        order_by: [asc: a.name],
        select: {m.group_id, a.name}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _reason} -> %{}
        rows -> Enum.group_by(rows, &elem(&1, 0), &elem(&1, 1))
      end
    end
  end
end
