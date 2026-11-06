defmodule Portal.Revocation.Failure do
  @moduledoc """
  Decides when a revocation mechanism has failed enough to stop using it.

  The list and the responder each keep their own failure clock and their own
  off switch. Each one is what the other falls back on: a connect asks the
  responder when the list is off or stale, so a list fault that also stopped the
  responder would leave revoked certificates working. A responder fault that
  stopped the list would do the same.

  Permanent faults disable at once. The addresses come out of a certificate
  rather than from configuration, so an address that is unroutable or of a
  scheme we do not speak will read the same way on every retry, and there is no
  version of waiting that changes it.

  Transient faults get a day. A CA whose CDN is down is a CA that will be back,
  and disabling on the first timeout would turn a short outage into one that
  lasts until someone notices.

  Nothing here re-enables a mechanism. A disabled one never fetches, so it can
  never observe its own recovery. Editing and saving the trust anchor the
  issuer belongs to is what clears it, which is also how a log sink comes back.
  """

  @transient_grace_hours 24

  @type mechanism :: :crl | :ocsp

  @doc """
  Columns to merge into the update recording a failed fetch.
  """
  @spec error_fields(Portal.RevocationEndpoint.t(), mechanism(), term(), DateTime.t()) ::
          keyword()
  def error_fields(endpoint, mechanism, reason, now) do
    {errored_field, disabled_field} = fields(mechanism)
    errored_at = Map.fetch!(endpoint, errored_field) || now

    if permanent?(reason) or DateTime.diff(now, errored_at, :hour) >= @transient_grace_hours do
      [{errored_field, errored_at}, {disabled_field, true}]
    else
      [{errored_field, errored_at}]
    end
  end

  @doc """
  Columns to merge into the update recording a successful fetch.
  """
  @spec success_fields(mechanism()) :: keyword()
  def success_fields(mechanism) do
    {errored_field, _disabled_field} = fields(mechanism)
    [{errored_field, nil}]
  end

  defp fields(:crl), do: {:crl_errored_at, :crl_is_disabled}
  defp fields(:ocsp), do: {:ocsp_errored_at, :ocsp_is_disabled}

  defp permanent?({:blocked_address, _message}), do: true
  defp permanent?(:unsupported_url_scheme), do: true
  defp permanent?(:no_crl_url), do: true
  defp permanent?(:no_ocsp_url), do: true
  defp permanent?(:issuer_certificate_missing), do: true
  defp permanent?(_reason), do: false
end
