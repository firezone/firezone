defmodule PortalAPI.MembershipController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias __MODULE__.Database

  tags ["Memberships"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Memberships",
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [
        in: :query,
        description: "Limit Memberships returned",
        type: :integer,
        example: 10
      ],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [ok: {"Membership Response", "application/json", PortalAPI.Schemas.Membership.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :not_found, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"group_id" => group_id} = params) do
    with {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, group_id: group_id),
         {:ok, actors, metadata} <- Database.list_actors(conn.assigns.subject, list_opts) do
      json(conn, JSON.encode(actors, metadata, schema: PortalAPI.Schemas.Membership.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update_put,
    summary: "Update Memberships",
    description: """
    Replaces the Group's entire membership list with the given Actors.

    Any Actor not named in the request is removed from the Group. To add or
    remove individual Actors without disturbing the rest, use `PATCH`.

    Members that are not changing keep their membership rows, so a replace that
    leaves the list untouched is a no-op rather than a full rewrite.

    Repeating an Actor in the request body is not an error; the list is
    deduplicated. `actor_ids` in the response is sorted, not returned in
    request order.
    """,
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Membership Attributes", "application/json", PortalAPI.Schemas.Membership.PutRequest,
       required: true},
    responses:
      [
        ok:
          {"Membership Response", "application/json",
           PortalAPI.Schemas.Membership.MembershipResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update_put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_put(conn, %{"group_id" => group_id, "memberships" => members})
      when is_list(members) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(group_id, subject),
         :ok <- validate_group_editable(group),
         {:ok, actor_ids} <- extract_actor_ids(members),
         :ok <- Database.validate_actors(actor_ids, subject),
         {:ok, actor_ids} <- Database.replace_members(group, actor_ids, subject) do
      json(conn, %{data: %{actor_ids: actor_ids}})
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_put(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update_patch,
    summary: "Update an Membership",
    description: """
    Adds and/or removes individual Actors, leaving every other member of the
    Group untouched.

    Both operations are idempotent: adding an Actor already in the Group and
    removing one that isn't are both no-ops. `remove` is applied before `add`,
    so an Actor named in both ends up in the Group. Retrying a request that may
    already have been applied is therefore safe.

    Repeating an Actor within `add` or `remove` is not an error; both lists are
    deduplicated. `actor_ids` in the response is sorted.
    """,
    parameters: [
      group_id: [
        in: :path,
        description: "ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Membership Attributes", "application/json", PortalAPI.Schemas.Membership.PatchRequest,
       required: true},
    responses:
      [
        ok:
          {"Membership Response", "application/json",
           PortalAPI.Schemas.Membership.MembershipResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update_patch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_patch(conn, %{"group_id" => group_id, "memberships" => params})
      when is_map(params) do
    subject = conn.assigns.subject

    with {:ok, group} <- Database.fetch_group(group_id, subject),
         :ok <- validate_group_editable(group),
         {:ok, add} <- extract_id_list(params, "add"),
         {:ok, remove} <- extract_id_list(params, "remove"),
         :ok <- Database.validate_actors(add, subject),
         {:ok, actor_ids} <- Database.patch_members(group, add, remove, subject) do
      json(conn, %{data: %{actor_ids: actor_ids}})
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_patch(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp validate_group_editable(group) do
    if is_nil(group.directory_id) and group.type == :static do
      :ok
    else
      {:error, :forbidden, reason: "Group is not editable"}
    end
  end

  # Both PATCH lists are plain arrays of Actor IDs. Neither is checked against
  # real Actors before "remove" reaches the delete query, so a malformed ID
  # would raise an Ecto.Query.CastError - a 500 for what is just a malformed
  # request. Checking the format here turns it into a 422 naming the value.
  defp extract_id_list(params, field) do
    values = List.wrap(Map.get(params, field, []))

    case Enum.reject(values, &valid_actor_id?/1) do
      [] ->
        {:ok, Enum.uniq(values)}

      invalid ->
        {:error, :unprocessable_entity,
         validation_errors: %{memberships: Enum.map(invalid, &invalid_id_message/1)}}
    end
  end

  # Rejects malformed entries rather than skipping them. Dropping one would be
  # silent data loss on a replace: an entry missing actor_id would shrink the
  # list, and a body where every entry is malformed - {"memberships": [{}]} -
  # would look like an empty list and clear the Group while returning 200.
  #
  # An explicitly empty list is still how a caller clears a Group. The
  # distinction is between "no members" and "members I could not read".
  defp extract_actor_ids(members) do
    {actor_ids, invalid} =
      Enum.reduce(members, {[], []}, fn
        %{"actor_id" => actor_id}, {ids, invalid} ->
          if valid_actor_id?(actor_id),
            do: {[actor_id | ids], invalid},
            else: {ids, [invalid_id_message(actor_id) | invalid]}

        _entry, {ids, invalid} ->
          {ids, ["entry is missing an Actor ID" | invalid]}
      end)

    case invalid do
      [] -> {:ok, actor_ids |> Enum.reverse() |> Enum.uniq()}
      invalid -> {:error, :unprocessable_entity,
                  validation_errors: %{memberships: Enum.reverse(invalid)}}
    end
  end

  defp valid_actor_id?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_actor_id?(_value), do: false

  defp invalid_id_message(value) when is_binary(value), do: "#{value} is not a valid Actor ID"
  defp invalid_id_message(value), do: "#{inspect(value)} is not a valid Actor ID"

  defmodule Database do
    import Ecto.Query
    alias Portal.Actor
    alias Portal.Membership
    alias Portal.Safe

    def list_actors(subject, opts) do
      from(a in Actor, as: :actors)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def fetch_group(id, subject) do
      from(g in Portal.Group, where: g.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        group -> {:ok, group}
      end
    end

    @doc """
    Verifies every given ID names an Actor in the subject's account.

    The `memberships_actor_id_fkey` constraint would reject a nonexistent
    Actor anyway, but only as an opaque constraint error at insert time - and
    a cross-account ID would surface the same way. Checking up front turns
    both into one 422 that names the offending IDs, and keeps the scoped query
    from confirming that an Actor in another account exists.
    """
    def validate_actors([], _subject), do: :ok

    def validate_actors(actor_ids, subject) do
      actor_ids = Enum.uniq(actor_ids)

      case existing_actor_ids(actor_ids, subject) do
        # Safe.all/1 returns {:error, :unauthorized} for a subject that may
        # not read Actors. An account_user reaches here - it may read a Group
        # but not an Actor - so this has to propagate rather than be treated
        # as "found nothing", which would report every ID as nonexistent.
        {:error, reason} -> {:error, reason}
        found -> validate_none_missing(actor_ids -- found)
      end
    end

    defp existing_actor_ids(actor_ids, subject) do
      from(a in Actor, where: a.id in ^actor_ids, select: a.id)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp validate_none_missing([]), do: :ok

    defp validate_none_missing(missing) do
      {:error, :unprocessable_entity,
       validation_errors: %{
         memberships: Enum.map(missing, &"#{&1} is not an Actor in this account")
       }}
    end

    @doc """
    Replaces the Group's membership with `actor_ids`.

    Diffs against what's stored and applies only the difference, so members
    that aren't changing keep their rows - and their IDs - rather than being
    deleted and reinserted. Reinserting would cascade away their
    `policy_authorizations` and churn the replication stream the data plane
    consumes.
    """
    def replace_members(group, actor_ids, subject) do
      actor_ids = Enum.uniq(actor_ids)

      Safe.transact(fn ->
        existing = existing_member_ids(group, subject)

        with :ok <- delete_members(group, existing -- actor_ids, subject),
             :ok <- insert_members(group, actor_ids -- existing, subject) do
          {:ok, Enum.sort(actor_ids)}
        end
      end)
    end

    @doc """
    Adds and removes individual members, leaving the rest of the Group alone.
    Removals are applied first, so an ID in both lists stays.
    """
    def patch_members(group, add, remove, subject) do
      add = Enum.uniq(add)
      # An ID in both lists is kept: remove runs first, then add puts it back,
      # so dropping it from remove up front is the same outcome with one less
      # write.
      remove = Enum.uniq(remove) -- add

      Safe.transact(fn ->
        existing = existing_member_ids(group, subject)

        # Deleting an ID that isn't a member matches no rows, so remove needs
        # no intersection with existing first.
        with :ok <- delete_members(group, remove, subject),
             :ok <- insert_members(group, add -- existing, subject) do
          {:ok, Enum.sort(Enum.uniq((existing -- remove) ++ add))}
        end
      end)
    end

    defp existing_member_ids(group, subject) do
      from(m in Membership, where: m.group_id == ^group.id, select: m.actor_id)
      |> Safe.scoped(subject)
      |> Safe.all()
      |> case do
        {:error, _reason} -> []
        ids -> ids
      end
    end

    defp delete_members(_group, [], _subject), do: :ok

    defp delete_members(group, actor_ids, subject) do
      from(m in Membership, where: m.group_id == ^group.id and m.actor_id in ^actor_ids)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
      |> case do
        {:error, reason} -> {:error, reason}
        {_count, _} -> :ok
      end
    end

    defp insert_members(_group, [], _subject), do: :ok

    defp insert_members(group, actor_ids, subject) do
      entries =
        Enum.map(actor_ids, fn actor_id ->
          %{
            id: Ecto.UUID.generate(),
            account_id: group.account_id,
            group_id: group.id,
            actor_id: actor_id
          }
        end)

      Safe.scoped(subject)
      |> Safe.insert_all(Membership, entries,
        on_conflict: :nothing,
        conflict_target: [:actor_id, :group_id]
      )
      |> case do
        {:error, reason} -> {:error, reason}
        {_count, _} -> :ok
      end
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :group_id,
          title: "Group",
          type: {:string, :uuid},
          fun: &filter_by_group_id/2
        }
      ]
    end

    defp filter_by_group_id(queryable, group_id) do
      dynamic =
        dynamic(
          [actors: a],
          a.id in subquery(
            from(m in Membership,
              where: m.group_id == ^group_id,
              select: m.actor_id
            )
          )
        )

      {queryable, dynamic}
    end
  end
end
