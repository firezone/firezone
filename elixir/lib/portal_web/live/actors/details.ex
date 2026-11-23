defmodule PortalWeb.Actors.Details do
  @moduledoc """
  What the People and Service accounts pages show about an actor beyond its own
  row: its groups and last activity in the list, and its devices, what it can
  reach and the groups it can be added to in the modal.

  Groups owned by a resource (direct access) are never returned as groups.

  The modal's lists load after the actor itself, each as an `{:actor_related, key}`
  async task that returns `{actor_id, records}`. A result for an actor that is no
  longer selected is dropped.
  """
  alias __MODULE__.Database
  alias Phoenix.LiveView.AsyncResult

  require Phoenix.LiveView

  @related_keys ~w[identities groups tokens sessions devices reach]a

  defdelegate put_list_details(actors, subject), to: Database
  defdelegate list_devices(actor_id, subject), to: Database
  defdelegate list_reach(actor_id, subject), to: Database
  defdelegate fetch_manual_group(group_id, subject), to: Database

  def related_state(created_token \\ nil) do
    @related_keys
    |> Map.new(&{&1, AsyncResult.loading()})
    |> Map.put(:created_token, created_token)
  end

  def start_related(socket, actor, keys, loader) do
    subject = socket.assigns.subject
    actor_id = actor.id

    Enum.reduce(keys, socket, fn key, acc ->
      Phoenix.LiveView.start_async(acc, {:actor_related, key}, fn ->
        {actor_id, loader.(key, actor_id, subject)}
      end)
    end)
  end

  def put_related(socket, key, records) do
    socket
    |> Phoenix.LiveView.cancel_async({:actor_related, key})
    |> update_related(key, &AsyncResult.ok(&1, records))
  end

  def handle_related_async({:actor_related, key}, {:ok, {actor_id, result}}, socket) do
    cond do
      not match?(%{id: ^actor_id}, socket.assigns.selected_actor) ->
        socket

      is_list(result) ->
        update_related(socket, key, &AsyncResult.ok(&1, result))

      true ->
        update_related(socket, key, &AsyncResult.failed(&1, result))
    end
  end

  def handle_related_async({:actor_related, _key}, {:exit, {:shutdown, :cancel}}, socket),
    do: socket

  def handle_related_async({:actor_related, key}, {:exit, reason}, socket) do
    update_related(socket, key, &AsyncResult.failed(&1, {:exit, reason}))
  end

  def loaded(%AsyncResult{ok?: true, result: records}), do: records
  def loaded(_result), do: []

  defp update_related(socket, key, fun) do
    Phoenix.Component.update(socket, :actor_related, &Map.update!(&1, key, fun))
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Presence
    alias Portal.Safe

    def put_list_details([], _subject), do: []

    def put_list_details(actors, subject) do
      ids = Enum.map(actors, & &1.id)

      groups_by_actor =
        from(m in Portal.Membership,
          join: g in Portal.Group,
          on: g.id == m.group_id and g.account_id == m.account_id,
          where: m.actor_id in ^ids and is_nil(g.resource_id),
          order_by: [asc: g.name],
          select: {m.actor_id, g}
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> list_or_empty()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      last_seen_by_actor =
        from(da in Portal.DeviceActor,
          where: da.actor_id in ^ids,
          group_by: da.actor_id,
          select: {da.actor_id, max(da.last_seen_at)}
        )
        |> Safe.scoped(subject)
        |> Safe.all()
        |> list_or_empty()
        |> Map.new()

      Enum.map(actors, fn actor ->
        %{
          actor
          | groups: Map.get(groups_by_actor, actor.id, []),
            last_seen_at: Map.get(last_seen_by_actor, actor.id)
        }
      end)
    end

    def list_devices(actor_id, subject) do
      from(d in Portal.Device,
        join: da in Portal.DeviceActor,
        on: da.device_id == d.id and da.account_id == d.account_id,
        where: da.actor_id == ^actor_id,
        order_by: [desc: da.last_seen_at],
        limit: 50
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> list_or_empty()
      |> Presence.Devices.preload_presence()
    end

    def list_reach(actor_id, subject) do
      from(p in Portal.Policy,
        join: g in Portal.Group,
        on: g.id == p.group_id and g.account_id == p.account_id,
        join: m in Portal.Membership,
        on: m.group_id == g.id and m.account_id == g.account_id,
        join: r in Portal.Resource,
        on: r.id == p.resource_id and r.account_id == p.account_id,
        left_join: s in Portal.Site,
        on: s.id == r.site_id and s.account_id == r.account_id,
        where: m.actor_id == ^actor_id and p.is_disabled == false,
        order_by: [asc: r.name, asc: g.name],
        select: %{resource: r, group: g, site_name: s.name}
      )
      |> Safe.scoped(subject)
      |> Safe.all()
      |> list_or_empty()
    end

    def fetch_manual_group(group_id, subject) do
      from(g in Portal.Group,
        where: g.id == ^group_id,
        where: g.type == :static and is_nil(g.idp_id) and is_nil(g.resource_id)
      )
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    defp list_or_empty(list) when is_list(list), do: list
    defp list_or_empty(_error), do: []
  end
end
