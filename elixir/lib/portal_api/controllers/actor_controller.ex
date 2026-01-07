defmodule PortalAPI.ActorController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs
  alias PortalAPI.Pagination
  alias Portal.Safe
  alias __MODULE__.DB
  import Ecto.Changeset

  action_fallback PortalAPI.FallbackController

  tags ["Actors"]

  operation :index,
    summary: "List Actors",
    parameters: [
      limit: [in: :query, description: "Limit Users returned", type: :integer, example: 10],
      page_cursor: [in: :query, description: "Next/Prev page cursor", type: :string]
    ],
    responses: [
      ok: {"ActorsResponse", "application/json", PortalAPI.Schemas.Actor.ListResponse}
    ]

  # List Actors
  def index(conn, params) do
    list_opts = Pagination.params_to_list_opts(params)

    with {:ok, actors, metadata} <- DB.list_actors(conn.assigns.subject, list_opts) do
      render(conn, :index, actors: actors, metadata: metadata)
    end
  end

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
    responses: [
      ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}
    ]

  # Show a specific Actor
  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- DB.fetch_actor(id, conn.assigns.subject) do
      render(conn, :show, actor: actor)
    end
  end

  operation :create,
    summary: "Create an Actor",
    request_body:
      {"Actor attributes", "application/json", PortalAPI.Schemas.Actor.Request, required: true},
    responses: [
      ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}
    ]

  # Create a new Actor
  def create(conn, %{"actor" => params}) do
    subject = conn.assigns.subject
    account = subject.account
    actor_type = normalize_actor_type(params["type"])

    # Check billing limits based on actor type
    with :ok <- check_billing_limits(account, actor_type),
         changeset <- create_actor_changeset(account, params),
         {:ok, actor} <- DB.insert_actor(changeset, subject) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/actors/#{actor}")
      |> render(:show, actor: actor)
    end
  end

  def create(_conn, _params) do
    {:error, :bad_request}
  end

  defp normalize_actor_type("service_account"), do: :service_account
  defp normalize_actor_type("account_admin_user"), do: :account_admin_user
  defp normalize_actor_type("account_user"), do: :account_user
  defp normalize_actor_type(_), do: nil

  defp check_billing_limits(account, :service_account) do
    if Portal.Billing.can_create_service_accounts?(account) do
      :ok
    else
      {:error, :service_accounts_limit_reached}
    end
  end

  defp check_billing_limits(account, :account_admin_user) do
    cond do
      not Portal.Billing.can_create_users?(account) ->
        {:error, :users_limit_reached}

      not Portal.Billing.can_create_admin_users?(account) ->
        {:error, :admins_limit_reached}

      true ->
        :ok
    end
  end

  defp check_billing_limits(account, :account_user) do
    if Portal.Billing.can_create_users?(account) do
      :ok
    else
      {:error, :users_limit_reached}
    end
  end

  defp check_billing_limits(_account, _type), do: :ok

  operation :update,
    summary: "Update an Actor",
    parameters: [
      id: [
        in: :path,
        description: "Actor ID",
        type: :string,
        example: "00000000-0000-0000-0000-000000000000"
      ]
    ],
    request_body:
      {"Actor attributes", "application/json", PortalAPI.Schemas.Actor.Request, required: true},
    responses: [
      ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}
    ]

  # Update an Actor
  def update(conn, %{"id" => id, "actor" => params}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- DB.fetch_actor(id, subject),
         changeset <- actor_changeset(actor, params),
         {:ok, actor} <- DB.update_actor(changeset, subject) do
      render(conn, :show, actor: actor)
    end
  end

  def update(_conn, _params) do
    {:error, :bad_request}
  end

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
    responses: [
      ok: {"ActorResponse", "application/json", PortalAPI.Schemas.Actor.Response}
    ]

  # Delete an Actor
  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, actor} <- DB.fetch_actor(id, subject),
         {:ok, actor} <- DB.delete_actor(actor, subject) do
      render(conn, :show, actor: actor)
    end
  end

  defp create_actor_changeset(account, attrs) do
    %Portal.Actor{account_id: account.id}
    |> cast(attrs, [:name, :email, :type, :allow_email_otp_sign_in])
    |> validate_required([:name, :type])
  end

  defp actor_changeset(actor, attrs) do
    actor
    |> cast(attrs, [:name, :email, :type, :allow_email_otp_sign_in])
    |> validate_required([:name, :type])
  end

  defmodule DB do
    import Ecto.Query
    alias Portal.Safe

    def list_actors(subject, opts \\ []) do
      from(a in Portal.Actor, as: :actors)
      |> Safe.scoped(subject)
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
      |> Safe.scoped(subject)
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
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_actor(actor, subject) do
      actor
      |> Safe.scoped(subject)
      |> Safe.delete()
    end
  end
end
