defmodule Portal.Analytics.PostHog do
  @moduledoc """
  Sends consented website attribution events to PostHog without affecting auth flows.
  """

  require Logger

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

    dispatch("Portal Attribution Received", attribution["distinct_id"], properties)
  end

  @spec identify_actor(Portal.Actor.t(), Portal.Account.t(), attribution() | nil) :: :ok
  def identify_actor(_actor, _account, nil), do: :ok

  def identify_actor(actor, account, attribution) do
    {event, distinct_id, properties} = identify_event(actor, account, attribution)
    dispatch(event, distinct_id, properties)
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
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    if Keyword.fetch!(config, :enabled) do
      body = %{
        "api_key" => Keyword.fetch!(config, :project_api_key),
        "event" => event,
        "properties" => Map.put(properties, "distinct_id", distinct_id)
      }

      req_opts = [json: body] ++ Keyword.get(config, :req_opts, [])

      case Req.post(Keyword.fetch!(config, :endpoint), req_opts) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp dispatch(event, distinct_id, properties) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    if Keyword.fetch!(config, :enabled) do
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
