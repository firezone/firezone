defmodule Portal.Entra.Webhooks do
  @moduledoc """
  Turns Microsoft Graph change and lifecycle notifications into Oban jobs.

  Each notification carries the `clientState` the subscription was created
  with. Notifications whose `clientState` does not match the directory's
  `webhook_secret` are dropped.
  """

  alias Portal.Entra
  alias __MODULE__.Database
  require Logger

  def handle_notifications(directory_id, notifications) when is_list(notifications) do
    with {:ok, id} <- Ecto.UUID.cast(directory_id || ""),
         %Entra.Directory{} = directory <- Database.get_directory(id) do
      notifications = authentic(directory, notifications)
      {lifecycle, changes} = Enum.split_with(notifications, &Map.has_key?(&1, "lifecycleEvent"))

      changes =
        changes
        |> Enum.map(&parse_change(directory, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> in_scope(directory)

      (Enum.map(lifecycle, &lifecycle_job(directory, &1)) ++ Enum.map(changes, &change_job(directory, &1)))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.changes)
      |> Enum.each(fn changeset ->
        {:ok, _job} = Oban.insert(changeset)
      end)

      :ok
    else
      _ ->
        Logger.warning("Dropping Entra notifications for unknown directory",
          entra_directory_id: directory_id
        )

        :ok
    end
  end

  def handle_notifications(_directory_id, _notifications), do: :ok

  defp authentic(directory, notifications) do
    {authentic, rejected} = Enum.split_with(notifications, &authentic?(directory, &1))

    if rejected != [] do
      Logger.warning("Dropping Entra notifications with a missing or invalid clientState",
        entra_directory_id: directory.id,
        count: length(rejected)
      )
    end

    authentic
  end

  defp authentic?(directory, %{"clientState" => client_state}) when is_binary(client_state) do
    Plug.Crypto.secure_compare(client_state, directory.webhook_secret)
  end

  defp authentic?(_directory, _notification), do: false

  defp lifecycle_job(directory, %{"lifecycleEvent" => event} = notification) do
    args = %{account_id: directory.account_id, directory_id: directory.id}

    case event do
      "reauthorizationRequired" ->
        Entra.Subscriptions.new(Map.put(args, :action, "renew"))

      "subscriptionRemoved" ->
        args
        |> Map.merge(%{action: "recreate", subscription_id: notification["subscriptionId"]})
        |> Entra.Subscriptions.new()

      "missed" ->
        Entra.Sync.new(args)

      other ->
        Logger.info("Ignoring unknown Entra lifecycle event",
          entra_directory_id: directory.id,
          lifecycle_event: inspect(other)
        )

        nil
    end
  end

  defp parse_change(directory, %{"changeType" => change_type, "resourceData" => %{} = data})
       when change_type in ["updated", "deleted"] do
    with resource when is_binary(resource) <- resource_kind(data),
         id when is_binary(id) <- data["id"] do
      {resource, id, change_type}
    else
      _ ->
        Logger.info("Ignoring Entra notification with unsupported resource",
          entra_directory_id: directory.id,
          resource_data: inspect(data)
        )

        nil
    end
  end

  defp parse_change(directory, notification) do
    Logger.info("Ignoring malformed Entra notification",
      entra_directory_id: directory.id,
      notification: inspect(notification)
    )

    nil
  end

  # Most changes in a tenant concern users and groups this directory never
  # synced. Those are dropped here so they never become jobs.
  defp in_scope([], _directory), do: []

  defp in_scope(changes, directory) do
    user_ids = for {"user", id, _} <- changes, do: id
    group_ids = for {"group", id, _} <- changes, do: id

    known_users = Database.known_user_ids(directory, user_ids)

    known_groups =
      if directory.sync_all_groups do
        MapSet.new(group_ids)
      else
        Database.known_group_ids(directory, group_ids)
      end

    Enum.filter(changes, fn
      {"user", id, _} -> MapSet.member?(known_users, id)
      {"group", id, _} -> MapSet.member?(known_groups, id)
    end)
  end

  defp change_job(directory, {resource, id, change_type}) do
    Entra.WebhookSync.new(%{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: resource,
      resource_id: id,
      change_type: change_type
    })
  end

  defp resource_kind(%{"@odata.type" => type}) when is_binary(type) do
    case String.downcase(type) do
      "#microsoft.graph.user" -> "user"
      "#microsoft.graph.group" -> "group"
      _ -> nil
    end
  end

  defp resource_kind(_data), do: nil

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(id) do
      from(d in Portal.Entra.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: not is_nil(d.webhook_secret),
        where: a.is_disabled == false,
        where: fragment("(?)->>'idp_sync' = 'true'", a.features)
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def known_user_ids(_directory, []), do: MapSet.new()

    def known_user_ids(directory, idp_ids) do
      issuer = Portal.Entra.Sync.issuer(directory)

      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^directory.account_id,
        where: i.issuer == ^issuer,
        where: i.idp_id in ^idp_ids,
        select: i.idp_id
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end

    def known_group_ids(_directory, []), do: MapSet.new()

    def known_group_ids(directory, idp_ids) do
      from(g in Portal.Group,
        where: g.account_id == ^directory.account_id,
        where: g.directory_id == ^directory.id,
        where: g.idp_id in ^idp_ids,
        select: g.idp_id
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> MapSet.new()
    end
  end
end
