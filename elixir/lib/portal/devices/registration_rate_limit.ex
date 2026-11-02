defmodule Portal.Devices.RegistrationRateLimit do
  @moduledoc """
  Account-wide throttle for registering new Client and Gateway device rows.

  Let E be `Portal.Accounts.Limits.device_allowance/1`. The shared Hammer bucket
  permits an initial burst of 2E registrations and refills E registrations per
  day. This allows an organization-wide rollout followed by replacement devices
  and ephemeral service accounts, without limiting the lifetime device count.
  Seat-exempt service-account add-ons contribute one device each to E.

  Call only after identity lookup establishes that a new row is needed, before
  insertion. Existing devices, credential renewals, and public-key changes are
  free. Deletion does not refund tokens. Failed inserts may consume a token;
  internal slug retries must not charge again. API/UI Gateway provisioning and
  both socket registration paths share the same bucket, across actors and IPs.

  An unlimited allowance bypasses the throttle. Hammer's existing PubSub
  replication is eventually consistent and counters reset on restart, so this
  is a registration throttle, not a strict distributed quota. Concurrent Relay
  allocation limits are enforced separately.
  """

  alias Portal.Account
  alias Portal.Accounts.Limits

  # Hammer refills integer tokens per second. Charging a day's worth of tokens
  # per registration expresses E registrations/day without rounding small
  # accounts up to one registration/second.
  @cost 86_400

  @spec check(Account.t()) :: :ok | {:error, {:rate_limit, non_neg_integer()}}
  def check(%Account{id: id, limits: limits}) do
    case Limits.device_allowance(limits) do
      nil ->
        :ok

      allowance ->
        case PortalAPI.RateLimit.hit(
               "device_registration:#{id}",
               allowance,
               2 * allowance * @cost,
               @cost
             ) do
          {:allow, _remaining} -> :ok
          {:deny, retry_after_ms} -> {:error, {:rate_limit, retry_after_ms}}
        end
    end
  end
end
