defmodule Portal.Analytics.PostHog do
  @moduledoc """
  Sends events to PostHog: consented website attribution events, sent without
  affecting auth flows, and batched product analytics.
  """

  require Logger

  @single_event_path "/i/v0/e/"
  @batch_path "/batch/"

  @type attribution :: map()

  @spec capture_portal_landing(attribution(), String.t()) :: :ok
  def capture_portal_landing(attribution, destination_path) do
    properties = %{
      "$insert_id" => insert_id([attribution["distinct_id"], destination_path]),
      "$process_person_profile" => false,
      "destination_path" => destination_path,
      "website_path" => attribution["website_path"],
      "website_source" => attribution["source"]
    }

    capture_async("Portal Attribution Received", attribution["distinct_id"], properties)
  end

  @spec identify_actor(Portal.Actor.t(), Portal.Account.t(), attribution() | nil) :: :ok
  def identify_actor(_actor, _account, nil), do: :ok

  def identify_actor(_actor, _account, attribution) when not is_map_key(attribution, "distinct_id"),
    do: :ok

  def identify_actor(actor, account, attribution) do
    {event, distinct_id, properties} = identify_event(actor, account, attribution)
    capture_async(event, distinct_id, properties)
  end

  @doc false
  def identify_event(actor, account, attribution) do
    profile_properties =
      %{
        "account_id" => account.id,
        "account_name" => account.name,
        "account_slug" => account.slug,
        "actor_type" => actor.type,
        "email" => actor.email,
        "name" => actor.name
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    properties = %{
      "$anon_distinct_id" => attribution["distinct_id"],
      "$insert_id" => insert_id([actor.id, attribution["distinct_id"]]),
      "$process_person_profile" => true,
      "$set" => profile_properties,
      "$set_once" => %{
        "initial_website_path" => attribution["website_path"],
        "initial_website_source" => attribution["source"]
      }
    }

    {"$identify", actor.id, properties}
  end

  @doc false
  @spec capture(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def capture(event, distinct_id, properties) do
    if enabled?() do
      post(@single_event_path, %{
        "event" => event,
        "properties" => Map.put(properties, "distinct_id", distinct_id)
      })
    else
      :ok
    end
  end

  @doc """
  Sends events through PostHog's batch endpoint. Each event is a map in PostHog's
  wire format, with `"event"`, `"properties"` (including `"distinct_id"`) and
  optionally `"timestamp"` and `"uuid"`.
  """
  @spec batch([map()]) :: :ok | {:error, term()}
  def batch([]), do: :ok

  def batch(events) do
    if enabled?() do
      post(@batch_path, %{"batch" => events})
    else
      :ok
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    :portal
    |> Portal.Config.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:enabled)
  end

  defp post(path, body) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    body = Map.put(body, "api_key", Keyword.fetch!(config, :project_api_key))

    req_opts =
      [base_url: Keyword.fetch!(config, :host), url: path, json: body] ++
        Keyword.get(config, :req_opts, [])

    case Req.post(req_opts) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sends an event in the background, so callers never wait on or fail because of PostHog.
  """
  @spec capture_async(String.t(), String.t(), map()) :: :ok
  def capture_async(event, distinct_id, properties) do
    if enabled?() do
      Task.Supervisor.start_child(
        Portal.Analytics.TaskSupervisor,
        fn -> capture_and_log(event, distinct_id, properties) end
      )
    end

    :ok
  end

  defp capture_and_log(event, distinct_id, properties) do
    case capture(event, distinct_id, properties) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("PostHog event failed", event: event, reason: reason)
    end
  end

  defp insert_id(parts) do
    parts
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
