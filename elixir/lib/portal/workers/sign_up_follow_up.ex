defmodule Portal.Workers.SignUpFollowUp do
  @moduledoc """
  Sends founder follow-up emails 15 minutes and 3 days after a web sign-up.

  The job carries only IDs. The recipient is loaded at send time so a disabled
  account or admin is skipped. A BCC to the HubSpot logging address attaches the
  email to the CRM contact.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity]

  alias Portal.Mailer
  alias __MODULE__.Database
  require Logger

  def enabled? do
    from_email = config()[:from_email]
    is_binary(from_email) and String.trim(from_email) != ""
  end

  def schedule(account, actor) do
    if enabled?() do
      # Keep the welcome args unchanged so existing queued jobs still deduplicate.
      for {extra_args, delay} <- [{%{}, {15, :minutes}}, {%{"stage" => "feedback"}, {3, :days}}] do
        schedule_email(account, actor, extra_args, delay)
      end
    end

    :ok
  end

  defp schedule_email(account, actor, extra_args, delay) do
    %{"account_id" => account.id, "actor_id" => actor.id}
    |> Map.merge(extra_args)
    |> new(schedule_in: delay)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not schedule sign-up follow-up email",
          account_id: account.id,
          reason: inspect(reason)
        )
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "actor_id" => actor_id} = args}) do
    case Database.fetch_recipient(account_id, actor_id) do
      %Portal.Actor{} = actor -> deliver(actor, Map.get(args, "stage", "welcome"))
      nil -> :ok
    end
  end

  defp deliver(actor, stage) do
    if enabled?() and
         :email in Portal.Actor.Preferences.channels(actor.preferences, :product_feedback_requests) do
      actor
      |> Mailer.SignUpFollowUpEmail.follow_up_email(config(), stage)
      |> Mailer.deliver_with_rate_limit(rate_limit_key: {:sign_up_follow_up, actor.account_id, stage})
      |> case do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp config, do: Portal.Config.get_env(:portal, __MODULE__, [])

  defmodule Database do
    import Ecto.Query
    alias Portal.Safe

    def fetch_recipient(account_id, actor_id) do
      from(actor in Portal.Actor,
        join: account in assoc(actor, :account),
        where: actor.id == ^actor_id,
        where: actor.account_id == ^account_id,
        where: actor.is_disabled == false,
        where: account.is_disabled == false,
        preload: [account: account]
      )
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
