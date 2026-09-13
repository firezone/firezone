defmodule Portal.Workers.DeleteUnattestedPolicyAuthorizations do
  @moduledoc """
  Oban worker that deletes the policy authorizations of clients that are no
  longer connected, for policies that require an attested device.

  Attestation is a property of the connection that presented the certificate,
  so once that connection is gone the authorization has nothing to stand on.
  Nothing else revokes it until it expires, which can be days away, and the
  gateway keeps serving the flow the whole time. A client that reconnects
  attests again and requests fresh authorizations.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias __MODULE__.Database
  alias Portal.Presence

  require Logger

  # Presence takes a moment to reach every node, so an authorization a client
  # just minted on another node is not mistaken for an orphan.
  @grace_secs 120

  @impl Oban.Worker
  def perform(_job) do
    minted_before = DateTime.add(DateTime.utc_now(), -@grace_secs, :second)

    count =
      minted_before
      |> Database.list_account_ids_requiring_attestation()
      |> Enum.map(fn account_id ->
        online_ids = Presence.Devices.online_ids(account_id, :client)
        {count, nil} = Database.delete_for_offline_clients(account_id, online_ids, minted_before)
        count
      end)
      |> Enum.sum()

    Logger.info("Deleted #{count} policy authorizations of offline clients on attested policies")

    :ok
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.{Policy, PolicyAuthorization, Safe}

    @attested_condition %{"property" => "device_attested", "operator" => "is", "values" => ["true"]}
    @attested_posture ~s|$.** ? (@.field == "firezone.attested" && @.value == true)|

    def list_account_ids_requiring_attestation(minted_before) do
      minted_before
      |> live_authorizations_on_attested_policies()
      |> select([policy_authorizations: pa], pa.account_id)
      |> distinct(true)
      |> Safe.unscoped()
      |> Safe.all()
    end

    def delete_for_offline_clients(account_id, online_ids, minted_before) do
      minted_before
      |> live_authorizations_on_attested_policies()
      |> where([policy_authorizations: pa], pa.account_id == ^account_id)
      |> where([policy_authorizations: pa], pa.initiating_device_id not in ^online_ids)
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    defp live_authorizations_on_attested_policies(minted_before) do
      from(pa in PolicyAuthorization, as: :policy_authorizations)
      |> join(:inner, [policy_authorizations: pa], p in Policy,
        on: p.id == pa.policy_id and p.account_id == pa.account_id,
        as: :policies
      )
      |> where([policy_authorizations: pa], pa.inserted_at < ^minted_before)
      |> where(
        [policy_authorizations: pa],
        is_nil(pa.expires_at) or pa.expires_at > ^DateTime.utc_now()
      )
      |> where(
        [policies: p],
        fragment("EXISTS (SELECT 1 FROM unnest(?) AS c WHERE c @> ?::jsonb)", p.conditions, ^@attested_condition) or
          fragment("jsonb_path_exists(?, ?::text::jsonpath)", p.postures, ^@attested_posture)
      )
    end
  end
end
