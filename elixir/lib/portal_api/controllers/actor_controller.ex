defmodule PortalAPI.ActorController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias PortalAPI.Error
  alias PortalAPI.Schemas.ProblemDetails
  alias Portal.Billing
  alias __MODULE__.Database
  import Ecto.Changeset

  tags ["Actors"]

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :index,
    summary: "List Actors",
    parameters: [
      limit: [in: :query, description: "Limit Users returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses:
      [ok: {"ActorsResponse", "application/json", PortalAPI.Schemas.Actor.ListResponse}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests])

  # coveralls-ignore-stop

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actors, metadata} <- Database.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :show,
    summary: "Show Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])

  # coveralls-ignore-stop

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Database.fetch_actor(id, conn.assigns.subject) do
      render(conn, :show, actor: actor)
    else
      error -> Error.handle(conn, error)
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :create,
    summary: "Create an Actor",
    request_body:
      {"Actor attributes", "application/json", PortalAPI.Schemas.Actor.CreateRequest,
       required: true},
    responses:
      [ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"actor" => params}) do
    subject = conn.assigns.subject
    account = subject.account
    actor_type = normalize_actor_type(params["type"])

    with :ok <- check_billing_limits(account, actor_type),
         changeset <- create_actor_changeset(account, params),
         {:ok, actor} <- Database.insert_actor(changeset, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actors/#{actor}")
      |> render(:show, actor: actor)
    else
      error -> Error.handle(conn, error)
    end
  end

  def create(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  defp normalize_actor_type("service_account"), do: :service_account
  defp normalize_actor_type("account_admin_user"), do: :account_admin_user
  defp normalize_actor_type("account_user"), do: :account_user
  defp normalize_actor_type(_), do: nil

  defp check_billing_limits(account, :service_account) do
    if Billing.can_create_service_accounts?(account) do
      :ok
    else
      {:error, :forbidden, reason: "Service accounts limit reached"}
    end
  end

  defp check_billing_limits(account, :account_admin_user) do
    cond do
      not Billing.can_create_users?(account) ->
        {:error, :forbidden, reason: "Users limit reached"}

      not Billing.can_create_admin_users?(account) ->
        {:error, :forbidden, reason: "Admins limit reached"}

      true ->
        :ok
    end
  end

  defp check_billing_limits(account, :account_user) do
    if Billing.can_create_users?(account) do
      :ok
    else
      {:error, :forbidden, reason: "Users limit reached"}
    end
  end

  defp check_billing_limits(_account, _type), do: :ok

  defp check_role_promotion_limits(account, actor, changeset) do
    new_type = get_change(changeset, :type)

    if actor.type != :account_admin_user and new_type == :account_admin_user and
         not Billing.can_create_admin_users?(account) do
      {:error, :forbidden, reason: "Admins limit reached"}
    else
      :ok
    end
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :update,
    summary: "Update an Actor",
    description: """
    Updates an Actor.

    **Warning: changing an Actor's email signs them out and unlinks their identity providers.**

    If the `email` field is changed to a different address, Firezone will:

    - Unlink every identity provider (Google, Okta, Entra, etc.) connected to this Actor.
    - End all active sessions for this Actor, both in the admin portal and on
      connected Client devices. The user will be signed out immediately.

    The Actor will need to sign in again through their identity provider, which
    re-links it under the new email.

    Email comparison ignores case and surrounding whitespace, so changes like
    `User@Example.com` → `user@example.com` are not treated as a real change
    and will not unlink identities.
    """,
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor attributes", "application/json", PortalAPI.Schemas.Actor.UpdateRequest,
       required: true},
    responses:
      [ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"id" => id, "actor" => params}) do
    subject = conn.assigns.subject
    account = subject.account

    with {:ok, actor} <- Database.fetch_actor(id, subject),
         changeset <- actor_changeset(actor, params),
         :ok <- check_role_promotion_limits(account, actor, changeset),
         {:ok, actor} <- Database.update_actor(changeset, subject) do
      render(conn, :show, actor: actor)
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  # coveralls-ignore-start - OpenApiSpex operation specs are compile-time, not executable
  operation :delete,
    summary: "Delete an Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    responses:
      [ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :too_many_requests, :not_found])

  # coveralls-ignore-stop

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- Database.fetch_actor(id, subject),
         {:ok, actor} <- Database.delete_actor(actor, subject) do
      render(conn, :show, actor: actor)
    else
      error -> Error.handle(conn, error)
    end
  end

  defp create_actor_changeset(account, attrs) do
    %Portal.Actor{account_id: account.id}
    |> cast(attrs, [:name, :email, :type, :allow_email_otp_sign_in])
    |> validate_required([:name, :type])
    |> validate_exclusion(:type, [:api_client],
      message: "API clients cannot be created via the API"
    )
  end

  defp actor_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :email, :type, :allow_email_otp_sign_in])
    |> validate_required([:name, :type])
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Actor
    alias Portal.ExternalIdentity
    alias Portal.Safe

    def list_actors(subject, opts \\ []) do
      from(a in Portal.Actor, as: :actors)
      |> Safe.scoped(subject, :replica)
      |> Safe.list(__MODULE__, opts)
    end

    def cursor_fields do
      [
        {:actors, :asc, :inserted_at},
        {:actors, :asc, :id}
      ]
    end

    def fetch_actor(id, subject) do
      from(a in Portal.Actor, where: a.id == ^id)
      |> Safe.scoped(subject, :replica)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        actor -> {:ok, actor}
      end
    end

    def insert_actor(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_actor(changeset, subject) do
      if Actor.email_meaningfully_changed?(changeset) do
        Safe.transact(fn -> update_actor_and_clear_identities(changeset, subject) end)
      else
        update_actor_changeset(changeset, subject)
      end
    end

    def delete_actor(actor, subject) do
      actor
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    defp update_actor_changeset(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    defp update_actor_and_clear_identities(changeset, subject) do
      actor_id = changeset.data.id

      with {:ok, actor} <- update_actor_changeset(changeset, subject),
           {_count, _} <- clear_identities_for_actor(actor_id, subject) do
        {:ok, actor}
      end
    end

    defp clear_identities_for_actor(actor_id, subject) do
      from(i in ExternalIdentity, where: i.actor_id == ^actor_id)
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end
  end
end
