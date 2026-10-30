defmodule PortalAPI.SentinelOnePostureProviderController do
  use PortalAPI, :controller
  use OpenApiSpex.ControllerSpecs

  alias PortalAPI.{Error, Pagination, Schemas.ProblemDetails}
  alias PortalAPI.JSON
  alias __MODULE__.Database
  import Ecto.Changeset

  tags ["SentinelOne Posture Providers"]

  plug :require_device_posture

  defp require_device_posture(conn, _opts) do
    if Portal.Account.device_posture_enabled?(conn.assigns.subject.account) do
      conn
    else
      conn
      |> Error.handle({:error, :forbidden, reason: "This feature is not enabled for your account."})
      |> Plug.Conn.halt()
    end
  end

  # coveralls-ignore-start
  operation :index,
    summary: "List SentinelOne posture providers",
    parameters: [
      limit: [in: :query, description: "Limit providers returned", schema: PortalAPI.Pagination.limit_schema()],
      page_cursor: [in: :query, description: "Next/previous page cursor", type: :string]
    ],
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.ListResponse}
      ] ++
        ProblemDetails.responses([:bad_request, :unauthorized, :forbidden, :too_many_requests])

  operation :show,
    summary: "Show a SentinelOne posture provider",
    parameters: [
      id: [in: :path, description: "SentinelOne posture provider ID", type: :string]
    ],
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :too_many_requests
        ])

  operation :update,
    summary: "Update a SentinelOne posture provider",
    description: """
    Renames, enables, or disables a SentinelOne posture provider. Connecting a
    provider or changing its tenant happens in the web console.

    A disabled provider stops syncing, and policies stop trusting its devices.
    Once no enabled SentinelOne provider is left, `sentinelone.*` posture rules see every
    device as not enrolled. Enabling requires a verified provider, clears any
    sync error, and queues a device sync.
    """,
    parameters: [
      id: [in: :path, description: "SentinelOne posture provider ID", type: :string]
    ],
    request_body:
      {"SentinelOne posture provider attributes", "application/json",
       PortalAPI.Schemas.SentinelOnePostureProvider.UpdateRequest, required: true},
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :too_many_requests
        ])

  operation :delete,
    summary: "Delete a SentinelOne posture provider",
    description: """
    Deletes a SentinelOne posture provider and every device synced from it. This
    cannot be undone. Policies keep their posture rules. Once no enabled SentinelOne
    provider is left, `sentinelone.*` posture rules see every device as not
    enrolled. Returns the deleted provider.
    """,
    parameters: [
      id: [in: :path, description: "SentinelOne posture provider ID", type: :string]
    ],
    responses:
      [
        ok:
          {"SentinelOne posture provider response", "application/json",
           PortalAPI.Schemas.SentinelOnePostureProvider.Response}
      ] ++
        ProblemDetails.responses([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :too_many_requests
        ])

  # coveralls-ignore-stop

  def index(conn, params) do
    with {:ok, opts} <- Pagination.params_to_list_opts(params),
         {:ok, providers, metadata} <- Database.list_providers(conn.assigns.subject, opts) do
      json(conn, JSON.encode(providers, metadata))
    else
      error -> Error.handle(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Database.fetch_provider(id, conn.assigns.subject) do
      json(conn, JSON.encode(provider))
    else
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, %{"id" => id, "sentinelone_posture_provider" => attrs}) when is_map(attrs) do
    subject = conn.assigns.subject

    with {:ok, provider} <- Database.fetch_provider(id, subject),
         {:ok, updated} <- provider |> update_changeset(attrs) |> Database.update_provider(subject) do
      if provider.is_disabled and not updated.is_disabled do
        Oban.insert(Portal.SentinelOne.Sync.new(%{"account_id" => updated.account_id, "posture_provider_id" => updated.id}))
      end

      json(conn, JSON.encode(updated))
    else
      {:error, %Ecto.Changeset{} = changeset} -> Error.handle(conn, {:error, hoist_name_errors(changeset)})
      error -> Error.handle(conn, error)
    end
  end

  def update(conn, _params) do
    Error.handle(conn, {:error, :bad_request})
  end

  def delete(conn, %{"id" => id}) do
    subject = conn.assigns.subject

    with {:ok, provider} <- Database.fetch_provider(id, subject),
         {:ok, _parent} <- Database.delete_provider(provider, subject) do
      json(conn, JSON.encode(provider))
    else
      error -> Error.handle(conn, error)
    end
  end

  defp update_changeset(provider, attrs) do
    %{provider | name: provider.posture_provider.name}
    |> cast(attrs, [:name, :is_disabled])
    |> validate_required([:is_disabled])
    |> put_name()
    |> put_disabled()
  end

  defp put_name(changeset) do
    case fetch_change(changeset, :name) do
      {:ok, name} ->
        parent =
          changeset.data.posture_provider
          |> change(name: name)
          |> Portal.PostureProvider.changeset()

        put_assoc(changeset, :posture_provider, parent)

      :error ->
        changeset
    end
  end

  defp put_disabled(changeset) do
    case fetch_change(changeset, :is_disabled) do
      {:ok, true} ->
        put_change(changeset, :disabled_reason, "Disabled by admin")

      {:ok, false} ->
        if changeset.data.is_verified do
          change(changeset, disabled_reason: nil, error_email_count: 0, error_message: nil, errored_at: nil)
        else
          add_error(changeset, :is_disabled, "Provider must be verified before enabling. Re-verify it in the web console.")
        end

      _other ->
        changeset
    end
  end

  defp hoist_name_errors(%Ecto.Changeset{changes: %{posture_provider: %Ecto.Changeset{errors: errors}}} = changeset) do
    Enum.reduce(errors, %{changeset | changes: Map.delete(changeset.changes, :posture_provider)}, fn
      {field, {message, opts}}, acc -> add_error(acc, field, message, opts)
    end)
  end

  defp hoist_name_errors(changeset), do: changeset

  defmodule Database do
    import Ecto.Query

    alias Portal.{Safe, SentinelOne}

    def list_providers(subject, opts) do
      from(p in SentinelOne.PostureProvider, as: :sentinelone_posture_providers)
      |> Safe.scoped(subject)
      |> Safe.list(__MODULE__, Keyword.put(opts, :preload, :posture_provider))
    end

    def fetch_provider(id, subject) do
      case from(p in SentinelOne.PostureProvider,
             where: p.id == ^id,
             preload: [:posture_provider]
           )
           |> Safe.scoped(subject)
           |> Safe.one() do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        provider -> {:ok, provider}
      end
    end

    def update_provider(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def delete_provider(provider, subject) do
      provider.posture_provider
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def cursor_fields do
      [
        {:sentinelone_posture_providers, :desc, :inserted_at},
        {:sentinelone_posture_providers, :desc, :id}
      ]
    end

    def preloads, do: []
  end
end
