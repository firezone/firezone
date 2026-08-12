defmodule Portal.Revocation.Failure do
  @moduledoc """
  Decides when a revocation endpoint has failed enough to stop fetching from.

  Shared by the list and the responder because what an admin is told is whether
  revocation works for this CA, not which of the two mechanisms broke. The two
  therefore share one streak clock, and a run of failures ends only once both
  are healthy.

  Permanent faults disable at once. The addresses come out of a certificate
  rather than from configuration, so an address that is unroutable or of a
  scheme we do not speak will read the same way on every retry, and there is no
  version of waiting that changes it.

  Transient faults get a day. A CA whose CDN is down is a CA that will be back,
  and disabling on the first timeout would turn a short outage into one that
  lasts until someone notices.

  Nothing here re-enables an endpoint. A disabled endpoint never fetches, so it
  can never observe its own recovery. Editing and saving the trust anchor the
  issuer belongs to is what clears it, which is also how a log sink comes back.
  """

  @disabled_reason "Fetch error"
  @transient_grace_hours 24

  @type mechanism :: :crl | :ocsp

  @spec disabled_reason() :: String.t()
  def disabled_reason, do: @disabled_reason

  @doc """
  Columns to merge into the update recording a failed fetch.
  """
  @spec error_fields(Portal.RevocationEndpoint.t(), term(), DateTime.t()) :: keyword()
  def error_fields(endpoint, reason, now) do
    errored_at = endpoint.errored_at || now

    if permanent?(reason) or DateTime.diff(now, errored_at, :hour) >= @transient_grace_hours do
      [errored_at: errored_at, is_disabled: true, disabled_reason: @disabled_reason]
    else
      [errored_at: errored_at]
    end
  end

  @doc """
  Columns to merge into the update recording a successful fetch.

  Empty while the other mechanism is still failing, so a working responder does
  not keep resetting the clock on a list that has been broken for days.
  """
  @spec success_fields(Portal.RevocationEndpoint.t(), mechanism()) :: keyword()
  def success_fields(endpoint, mechanism) do
    if is_nil(other_error(endpoint, mechanism)) do
      [errored_at: nil, error_email_count: 0, last_error_email_at: nil]
    else
      []
    end
  end

  defp other_error(endpoint, :crl), do: endpoint.ocsp_error
  defp other_error(endpoint, :ocsp), do: endpoint.crl_error

  defp permanent?({:blocked_address, _message}), do: true
  defp permanent?(:unsupported_url_scheme), do: true
  defp permanent?(:no_crl_url), do: true
  defp permanent?(:no_ocsp_url), do: true
  defp permanent?(:issuer_certificate_missing), do: true
  defp permanent?(_reason), do: false
end
