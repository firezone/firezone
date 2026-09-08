defmodule Portal.Okta.Webhooks do
  @moduledoc """
  Turns Okta event hook deliveries into Oban jobs.

  The admin registers the hook in Okta with the directory's endpoint and its
  `webhook_secret` as the Authorization header, so no API scope beyond the
  three the sync already holds is needed. Deliveries whose header does not
  match are refused. Events are only pings: each job re-reads the object.
  """

  alias Portal.DirectorySync
  alias Portal.Okta
  alias Portal.PubSub
  alias __MODULE__.Database
  require Logger

  @events ~w[
    user.lifecycle.create
    user.lifecycle.activate
    user.lifecycle.reactivate
    user.lifecycle.suspend
    user.lifecycle.unsuspend
    user.lifecycle.deactivate
    user.lifecycle.delete.initiated
    user.account.update_profile
    group.user_membership.add
    group.user_membership.remove
    group.lifecycle.update
    group.lifecycle.delete
    application.user_membership.add
    application.user_membership.remove
  ]

  # A user the directory does not know yet can only arrive through one of these.
  @admits_new_users ~w[
    user.lifecycle.create
    user.lifecycle.activate
    user.lifecycle.reactivate
    user.lifecycle.unsuspend
    group.user_membership.add
    application.user_membership.add
  ]

  @okta_id ~r/^[A-Za-z0-9_-]{1,64}$/

  @doc """
  The event types the hook should subscribe to.
  """
  def events, do: @events

  @doc """
  The URL the hook must be registered with.
  """
  def endpoint_url(directory_id) do
    base =
      (Portal.Config.get_env(:portal, :rest_api_url) ||
         Portal.Config.fetch_env!(:portal, :api_external_url))
      |> String.trim_trailing("/")

    "#{base}/integrations/okta/webhooks?directory_id=#{directory_id}"
  end

  @doc """
  Records that Okta reached the endpoint of a directory that can take events,
  and tells the settings page, which waits for exactly this.
  """
  def verify(directory_id) do
    with {:ok, id} <- Ecto.UUID.cast(directory_id || ""),
         %Okta.Directory{} = directory <- Database.get_directory(id) do
      Database.mark_verified(directory)
      PubSub.Changes.broadcast(directory.account_id, :directories, :directories_changed)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  def handle_events(directory_id, authorization, events) when is_list(events) do
    with {:ok, id} <- Ecto.UUID.cast(directory_id || ""),
         %Okta.Directory{} = directory <- Database.get_directory(id),
         true <- authentic?(directory, authorization) do
      Database.touch_received(directory)

      events
      |> Enum.flat_map(&parse_event(directory, &1))
      |> Enum.uniq()
      |> in_scope(directory)
      |> Enum.uniq_by(fn {resource, resource_id, _new?} -> {resource, resource_id} end)
      |> Enum.each(fn {resource, resource_id, _new?} ->
        {:ok, _job} = Oban.insert(change_job(directory, resource, resource_id))
      end)

      :ok
    else
      false ->
        Logger.warning("Refusing Okta events with a missing or invalid Authorization header",
          okta_directory_id: directory_id
        )

        {:error, :unauthorized}

      _ ->
        Logger.warning("Dropping Okta events for unknown directory",
          okta_directory_id: directory_id
        )

        {:error, :not_found}
    end
  end

  defp authentic?(directory, authorization) when is_binary(authorization) do
    Plug.Crypto.secure_compare(authorization, directory.webhook_secret)
  end

  defp authentic?(_directory, _authorization), do: false

  defp parse_event(directory, %{"eventType" => type, "target" => targets})
       when is_binary(type) and is_list(targets) do
    cond do
      String.starts_with?(type, "group.lifecycle.") ->
        for id <- target_ids(targets, "UserGroup"), do: {"group", id, false}

      String.starts_with?(type, ["user.", "group.user_membership.", "application.user_membership."]) ->
        for id <- target_ids(targets, "User"), do: {"user", id, type in @admits_new_users}

      true ->
        Logger.info("Ignoring Okta event of an unsupported type",
          okta_directory_id: directory.id,
          event_type: type
        )

        []
    end
  end

  defp parse_event(directory, event) do
    Logger.info("Ignoring malformed Okta event",
      okta_directory_id: directory.id,
      event: inspect(event)
    )

    []
  end

  defp target_ids(targets, type) do
    for %{"type" => ^type, "id" => id} <- targets, is_binary(id), Regex.match?(@okta_id, id), do: id
  end

  # Most events in an org concern users and groups this directory never
  # synced. Those are dropped here so they never become jobs, unless a job for
  # the directory is running: it may still insert the object from a response
  # fetched before this change. A user an event adds is kept even when unknown,
  # because that is how a user first reaches the directory.
  defp in_scope([], _directory), do: []

  defp in_scope(changes, directory) do
    if DirectorySync.busy?(:okta, directory.id) do
      changes
    else
      known_users = Database.known_user_ids(directory, for({"user", id, _} <- changes, do: id))
      known_groups = Database.known_group_ids(directory, for({"group", id, _} <- changes, do: id))

      Enum.filter(changes, fn
        {"user", id, new?} -> new? or MapSet.member?(known_users, id)
        {"group", id, _} -> MapSet.member?(known_groups, id)
      end)
    end
  end

  defp change_job(directory, resource, resource_id) do
    Okta.WebhookSync.new(%{
      account_id: directory.account_id,
      directory_id: directory.id,
      resource: resource,
      resource_id: resource_id
    })
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def get_directory(id) do
      from(d in Portal.Okta.Directory,
        join: a in Portal.Account,
        on: a.id == d.account_id,
        where: d.id == ^id,
        where: d.is_disabled == false,
        where: a.is_disabled == false
      )
      |> Safe.unscoped()
      |> Safe.one()
    end

    def mark_verified(directory) do
      from(d in Portal.Okta.Directory, where: d.id == ^directory.id)
      |> Safe.unscoped()
      |> Safe.update_all(set: [webhook_verified_at: DateTime.utc_now()])
    end

    def touch_received(directory) do
      from(d in Portal.Okta.Directory, where: d.id == ^directory.id)
      |> Safe.unscoped()
      |> Safe.update_all(set: [webhook_received_at: DateTime.utc_now()])
    end

    def known_user_ids(_directory, []), do: MapSet.new()

    def known_user_ids(directory, idp_ids) do
      from(i in Portal.ExternalIdentity,
        where: i.account_id == ^directory.account_id,
        where: i.issuer == ^Portal.Okta.Sync.issuer(directory),
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
