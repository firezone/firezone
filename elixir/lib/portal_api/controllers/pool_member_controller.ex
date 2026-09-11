defmodule PortalAPI.PoolMemberController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.JSON
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Resource
  alias __MODULE__.Database

  tags ["Pool Members"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Pool Members",
    description: """
    Lists the Clients a `device_pool` Resource names as its members.

    Returns 400 for any other Resource type, and for a device pool whose members are
    each actor's own devices rather than a list.
    """,
    parameters: [
      resource_id: [
        in: :path,
        description: "Resource ID",
        example: "00000000-0000-0000-0000-000000000000"
      ],
      limit: [in: :query, description: "Limit Pool Members returned", schema: PortalAPI.Pagination.limit_schema(), example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [ok: {"Pool Member Response", "application/json", PortalAPI.Schemas.PoolMember.ListResponse}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, %{"resource_id" => resource_id} = params) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Database.fetch_resource(resource_id, subject),
         :ok <- validate_device_pool(resource),
         {:ok, list_opts} <- Pagination.params_to_list_opts(params),
         list_opts = Keyword.put(list_opts, :filter, resource_id: resource_id),
         {:ok, clients, metadata} <- Database.list_devices(subject, list_opts) do
      json(conn, JSON.encode(clients, metadata, schema: PortalAPI.Schemas.PoolMember.Schema))
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update_put,
    summary: "Replace Pool Members",
    description: """
    Replaces the Resource's entire membership list with the given Clients.

    Any Client not named in the request is removed from the pool. To add or
    remove individual Clients without disturbing the rest, use `PATCH`.
    """,
    parameters: [
      resource_id: [
        in: :path,
        description: "Resource ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Pool Member Attributes", "application/json", PortalAPI.Schemas.PoolMember.PutRequest,
       required: true},
    responses:
      [
        ok:
          {"Pool Member Response", "application/json",
           PortalAPI.Schemas.PoolMember.PoolMemberResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update_put(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_put(conn, %{"resource_id" => resource_id, "pool_members" => members})
      when is_list(members) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Database.fetch_resource(resource_id, subject),
         :ok <- validate_device_pool(resource),
         {:ok, device_ids} <- extract_device_ids(members),
         :ok <- Database.validate_client_devices(device_ids, subject),
         {:ok, device_ids} <- Database.replace_members(resource, device_ids, subject) do
      json(conn, %{data: %{device_ids: device_ids}})
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_put(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update_patch,
    summary: "Add or Remove Pool Members",
    description: """
    Adds and/or removes individual Clients, leaving every other member of the
    pool untouched.

    Both operations are idempotent: adding a Client already in the pool and
    removing one that isn't are both no-ops. `remove` is applied before `add`,
    so a Client named in both ends up in the pool.
    """,
    parameters: [
      resource_id: [
        in: :path,
        description: "Resource ID",
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Pool Member Attributes", "application/json", PortalAPI.Schemas.PoolMember.PatchRequest,
       required: true},
    responses:
      [
        ok:
          {"Pool Member Response", "application/json",
           PortalAPI.Schemas.PoolMember.PoolMemberResponse}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update_patch(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_patch(conn, %{"resource_id" => resource_id, "pool_members" => params})
      when is_map(params) do
    subject = conn.assigns.subject

    with {:ok, resource} <- Database.fetch_resource(resource_id, subject),
         :ok <- validate_device_pool(resource),
         {:ok, add} <- extract_id_list(params, "add"),
         {:ok, remove} <- extract_id_list(params, "remove"),
         :ok <- Database.validate_client_devices(add, subject),
         {:ok, device_ids} <- Database.patch_members(resource, add, remove, subject) do
      json(conn, %{data: %{device_ids: device_ids}})
    else
      error -> Error.handle(conn, error)
    end
  end

  def update_patch(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # Only device pools that list their members have a member list. Everything else is
  # rejected rather than returning an empty list, so a request against the wrong
  # Resource fails loudly instead of looking like an empty pool.
  defp validate_device_pool(%Resource{type: :device_pool} = resource) do
    case Resource.DeviceMembershipCriteria.device_ids(resource.device_membership_criteria) do
      {:ok, _device_ids} ->
        :ok

      :error ->
        {:error, :bad_request,
         reason: "Resource has no member list; its members are each actor's own devices"}
    end
  end

  defp validate_device_pool(%Resource{type: type}) do
    {:error, :bad_request,
     reason: "Resource type #{type} has no pool members; only device_pool does"}
  end

  # Both PATCH lists are plain arrays of Client IDs. Only "add" is checked
  # against real Clients later, so a non-binary in "remove" would reach
  # the delete query and raise an Ecto.Query.CastError - a 500 for what is
  # just a malformed request.
  defp extract_id_list(params, field) do
    values = List.wrap(Map.get(params, field, []))

    case Enum.reject(values, &is_binary/1) do
      [] ->
        {:ok, values}

      _invalid ->
        {:error, :unprocessable_entity,
         validation_errors: %{field => ["must be a list of Client ID strings"]}}
    end
  end

  # Rejects malformed entries rather than skipping them. Dropping one
  # would be silent data loss on a replace: an entry missing device_id
  # would shrink the list, and a body where every entry is malformed -
  # {"pool_members": [{}]} - would look like an empty list and clear the
  # pool while returning 200.
  #
  # An explicitly empty list is still how a caller clears a pool. The
  # distinction is between "no members" and "members I could not read".
  defp extract_device_ids(members) do
    {device_ids, invalid_indexes} =
      members
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn
        {%{"device_id" => device_id}, _index}, {ids, invalid} when is_binary(device_id) ->
          {[device_id | ids], invalid}

        {_entry, index}, {ids, invalid} ->
          {ids, [index | invalid]}
      end)

    case invalid_indexes do
      [] ->
        {:ok, Enum.reverse(device_ids)}

      invalid ->
        {:error, :unprocessable_entity,
         validation_errors: %{
           pool_members:
             invalid
             |> Enum.reverse()
             |> Enum.map(&"entry #{&1} is missing a string device_id")
         }}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Device
    alias Portal.Safe
    alias Portal.Resource.DeviceMembershipCriteria

    def fetch_resource(id, subject) do
      from(r in Portal.Resource, where: r.id == ^id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        resource -> {:ok, resource}
      end
    end

    def list_devices(subject, opts \\ []) do
      from(d in Device, as: :devices)
      |> where([devices: d], d.type == :client)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, opts)
    end

    def filters do
      [
        %Portal.Repo.Filter{
          name: :resource_id,
          title: "Resource",
          type: {:string, :uuid},
          fun: &filter_by_resource_id/2
        }
      ]
    end

    defp filter_by_resource_id(queryable, resource_id) do
      queryable =
        join(queryable, :inner, [devices: d], r in Portal.Resource,
          on:
            r.account_id == d.account_id and r.id == ^resource_id and
              fragment(
                "jsonb_exists(? #> '{device,value}', ?::text)",
                r.device_membership_criteria,
                d.id
              ),
          as: :pool
        )

      {queryable, dynamic(true)}
    end

    def cursor_fields do
      [
        {:devices, :asc, :inserted_at},
        {:devices, :asc, :id}
      ]
    end

    @doc """
    Verifies every given ID names a Client device in the subject's account, so a
    Gateway, a nonexistent or a cross-account ID answers with one 422 that names
    the offending IDs.
    """
    def validate_client_devices([], _subject), do: :ok

    def validate_client_devices(device_ids, subject) do
      device_ids = Enum.uniq(device_ids)

      case existing_client_device_ids(device_ids, subject) do
        # Safe.all/1 returns {:error, :unauthorized} for a subject that may
        # not read Devices. No actor type can reach here without that
        # permission today, but treating the tuple as an empty result would
        # answer an authorization failure with a 422 claiming every ID is
        # nonexistent, so it propagates instead.
        {:error, reason} -> {:error, reason}
        found -> validate_none_missing(device_ids -- found)
      end
    end

    defp existing_client_device_ids(device_ids, subject) do
      from(d in Device, where: d.id in ^device_ids and d.type == :client, select: d.id)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    defp validate_none_missing([]), do: :ok

    defp validate_none_missing(missing) do
      {:error, :unprocessable_entity,
       validation_errors: %{
         pool_members: Enum.map(missing, &"#{&1} is not a Client in this account")
       }}
    end

    @doc """
    Replaces the pool's member list with `device_ids`.
    """
    def replace_members(resource, device_ids, subject) do
      device_ids = Enum.uniq(device_ids)

      Safe.transact(fn ->
        with {:ok, _resource} <- lock_resource(resource, subject),
             {:ok, resource} <- put_members(resource, device_ids, subject) do
          {:ok, member_ids(resource)}
        end
      end)
    end

    @doc """
    Adds and removes individual members, leaving the rest of the pool
    alone. Removals are applied first, so an ID in both lists stays.
    """
    def patch_members(resource, add, remove, subject) do
      add = Enum.uniq(add)
      # An ID in both lists is kept: remove runs first, then add puts it
      # back, so dropping it from remove up front is the same outcome
      # with one less write.
      remove = Enum.uniq(remove) -- add

      Safe.transact(fn ->
        with {:ok, resource} <- lock_resource(resource, subject),
             existing = member_ids(resource),
             {:ok, resource} <-
               put_members(resource, Enum.uniq((existing -- remove) ++ add), subject) do
          {:ok, member_ids(resource)}
        end
      end)
    end

    # Both writes read the list before rewriting it, so concurrent patches queue up
    # on the row instead of overwriting each other.
    defp lock_resource(resource, subject) do
      from(r in Portal.Resource, where: r.id == ^resource.id, lock: "FOR UPDATE")
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        %Portal.Resource{} = resource -> {:ok, resource}
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end

    defp put_members(resource, device_ids, subject) do
      resource
      |> Ecto.Changeset.cast(
        %{device_membership_criteria: DeviceMembershipCriteria.devices(device_ids)},
        [:device_membership_criteria]
      )
      |> Portal.Resource.changeset()
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    defp member_ids(resource) do
      {:ok, device_ids} =
        DeviceMembershipCriteria.device_ids(resource.device_membership_criteria)

      device_ids
    end
  end
end
