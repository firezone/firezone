defmodule Portal.Avatars.Picture do
  @moduledoc """
  Oban worker that copies the photo at an identity's `picture` URL, which the
  identity provider sends at sign-in, to `Portal.Avatars`.

  Sign-in queues it. A changed URL runs at once, and the same URL runs at most
  once a day. The photo is downloaded each run, but only stored again when its
  bytes change. A directory photo always wins, so identities that have one are
  left alone.

  The URL comes from the identity provider, which for generic OIDC is
  configured by the customer, so the download goes through the SSRF guard and
  a size limit.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 24 * 60 * 60,
      states: [:available, :scheduled, :executing, :retryable, :completed],
      keys: [:identity_id, :picture]
    ]

  alias Portal.Avatars
  alias Portal.ExternalIdentity
  alias __MODULE__.Database
  require Logger

  @doc """
  Queues a run for an identity that just signed in, unless there is nothing
  to do. Never fails the sign-in.
  """
  def enqueue(%ExternalIdentity{} = identity) do
    if Avatars.enabled?() and (is_binary(identity.picture) or identity.avatar_source == :picture) do
      %{account_id: identity.account_id, identity_id: identity.id, picture: identity.picture}
      |> new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to queue profile photo job", reason: inspect(reason))
      end
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "identity_id" => identity_id}}) do
    with true <- Avatars.enabled?(),
         %ExternalIdentity{} = identity <- Database.get_identity(account_id, identity_id) do
      sync(identity)
    else
      _other -> :ok
    end
  end

  defp sync(%ExternalIdentity{avatar_source: :directory}), do: :ok

  defp sync(%ExternalIdentity{picture: "https://" <> _rest = url} = identity) do
    case download(url) do
      {:ok, body} ->
        version = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        if identity.avatar_source != :picture or identity.avatar_etag != version do
          Avatars.store(identity, :picture, version, body)
        end

        :ok

      {:error, :not_found} ->
        clear(identity)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # No URL, or one that is not HTTPS.
  defp sync(identity), do: clear(identity)

  defp clear(%ExternalIdentity{avatar_source: :picture} = identity), do: Avatars.clear(identity)
  defp clear(_identity), do: :ok

  # The SSRF guard is attached here as well, so it holds even where an
  # operator turns the global one off.
  defp download(url) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    (config[:req_opts] || [])
    |> Req.new()
    |> Portal.Req.SSRFProtection.attach(config[:ssrf_protection_opts] || [])
    |> Portal.Req.Bounded.request(
      url: url,
      allow_private_ips: false,
      max_body_bytes: Avatars.max_bytes(),
      timeout: :timer.seconds(30),
      raw: true
    )
    |> case do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} when status in [404, 410] -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, %Portal.Req.Bounded.BodyTooLargeError{}} -> {:error, :not_found}
      {:error, %Portal.Req.SSRFProtection.UnsafeURLError{}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.ExternalIdentity
    alias Portal.Safe

    def get_identity(account_id, id) do
      from(i in ExternalIdentity,
        where: i.account_id == ^account_id and i.id == ^id,
        select: struct(i, [:account_id, :id, :picture, :avatar_source, :avatar_etag])
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
