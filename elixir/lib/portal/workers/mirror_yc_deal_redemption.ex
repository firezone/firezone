defmodule Portal.Workers.MirrorYCDealRedemption do
  @moduledoc """
  Sends a YC deal redemption to the portal of another region, so that the
  founder can use their code in either region's Stripe account.

  The body and signature are sent as YC sent them, so the other portal checks
  the request like any YC request. Both portals derive the code from the
  signed body, so they create the same code.
  """

  use Oban.Worker,
    queue: :default,
    unique: [period: 86_400, keys: [:body]]

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"body" => body, "signature" => signature}}) do
    case Portal.Config.fetch_env!(:portal, :yc_deal_mirror_url) do
      url when is_binary(url) and url != "" -> post(url, body, signature)
      _url -> {:cancel, :no_mirror_url}
    end
  end

  defp post(url, body, signature) do
    req_opts()
    |> Req.new()
    |> Req.merge(
      url: url,
      params: [skip_email: "true"],
      headers: [{"content-type", "application/json"}, {"x-yc-signature", signature}],
      redirect: false
    )
    |> Req.post(body: body)
    |> case do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("YC deal redemption was not mirrored", status: status)
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end
