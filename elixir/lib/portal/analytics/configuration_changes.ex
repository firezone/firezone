defmodule Portal.Analytics.ConfigurationChanges do
  @moduledoc """
  Turns committed change log entries into `Configuration Changed` events for PostHog,
  recording which kind of object changed and whether the change came from the portal,
  the API or Terraform.

  Only configuration objects are tracked, and only changes made by an actor: writes
  without a subject, such as directory sync and background jobs, are skipped. Object
  data is never sent, only the object kind, the operation, the source and the
  account's name and slug.

  The source is inferred from the subject's actor type and user agent, since the
  subject recorded in the change log doesn't carry the authentication context:

    * `api_client` actors are API tokens: `terraform` when the user agent says so,
      otherwise `api`
    * other actors with a browser user agent are the `portal`
    * anything else is `other`, e.g. MCP or an admin's OAuth token calling the API
  """

  require Logger

  alias Portal.Analytics.PostHog
  alias __MODULE__.Database

  @event "Configuration Changed"
  @batch_size 500

  @objects %{
    "accounts" => "account",
    "actors" => "actor",
    "api_tokens" => "api_token",
    "gateway_tokens" => "gateway_token",
    "groups" => "group",
    "policies" => "policy",
    "resources" => "resource",
    "sites" => "site",
    "trust_anchors" => "trust_anchor"
  }

  # Provider tables are named `<type>_<kind>`, e.g. `okta_directories`.
  @typed_objects [
    {"_auth_providers", "auth_provider"},
    {"_directories", "directory"},
    {"_log_sinks", "log_sink"},
    {"_posture_providers", "posture_provider"}
  ]

  @doc """
  Sends the events for the given change log entries in the background, so the
  change log consumer never waits on PostHog.
  """
  @spec capture([map()]) :: :ok
  def capture(entries) do
    with true <- PostHog.enabled?(),
         [_ | _] = entries <- Enum.filter(entries, &tracked?/1) do
      Task.Supervisor.start_child(Portal.Analytics.TaskSupervisor, fn ->
        entries
        |> events(Database.fetch_accounts_by_id(entries))
        |> send_events()
      end)
    end

    :ok
  end

  @doc false
  @spec events([map()], %{Ecto.UUID.t() => map()}) :: [map()]
  def events(entries, accounts_by_id) do
    for entry <- entries, tracked?(entry) do
      {:ok, object, object_type} = object(entry.object)
      account = Map.get(accounts_by_id, entry.account_id, %{name: nil, slug: nil})
      event(entry, account, object, object_type)
    end
  end

  defp tracked?(entry) do
    match?(%{"actor_id" => actor_id} when is_binary(actor_id), entry.subject) and
      match?({:ok, _object, _object_type}, object(entry.object))
  end

  defp event(entry, account, object, object_type) do
    %{"actor_id" => actor_id} = subject = entry.subject

    properties =
      account
      |> PostHog.account_properties()
      |> Map.merge(%{
        "distinct_id" => actor_id,
        "$groups" => %{"account" => entry.account_id},
        "object" => object,
        "operation" => Atom.to_string(entry.operation),
        "source" => source(subject)
      })
      |> maybe_put("object_type", object_type)

    %{
      "event" => @event,
      "timestamp" => DateTime.to_iso8601(entry.timestamp),
      # Change log batches are replayed after a crash, so the same write must map
      # to the same event.
      "uuid" => PostHog.event_uuid([@event, entry.account_id, entry.lsn]),
      "properties" => properties
    }
  end

  defp object(table) when is_map_key(@objects, table), do: {:ok, Map.fetch!(@objects, table), nil}

  defp object(table) do
    Enum.find_value(@typed_objects, :error, fn {suffix, object} ->
      if String.ends_with?(table, suffix) and byte_size(table) > byte_size(suffix),
        do: {:ok, object, String.replace_suffix(table, suffix, "")}
    end)
  end

  defp source(%{"actor_type" => "api_client"} = subject) do
    if user_agent(subject) =~ ~r/terraform/i, do: "terraform", else: "api"
  end

  defp source(subject) do
    if user_agent(subject) =~ ~r/mozilla|chrome|safari|firefox/i, do: "portal", else: "other"
  end

  defp user_agent(%{"user_agent" => user_agent}) when is_binary(user_agent), do: user_agent
  defp user_agent(_subject), do: ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp send_events(events) do
    events
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      case PostHog.batch(batch) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("PostHog configuration changes failed", reason: inspect(reason))
      end
    end)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    # Includes disabled accounts, and leaves out deleted ones, whose changes are
    # then sent without a name and slug.
    def fetch_accounts_by_id(entries) do
      account_ids = entries |> Enum.map(& &1.account_id) |> Enum.uniq()

      from(a in Portal.Account,
        where: a.id in ^account_ids,
        select: {a.id, %{name: a.name, slug: a.slug}}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end
  end
end
