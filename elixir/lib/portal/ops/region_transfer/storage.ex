defmodule Portal.Ops.RegionTransfer.Storage do
  @moduledoc """
  Reads and writes the blobs of a region transfer. The source region writes an
  export to a container in the destination region (`region_transfer_outbox_url`)
  and the destination reads it from its own (`region_transfer_inbox_url`).
  Requests carry the portal's managed identity token.
  """

  @api_version "2020-12-06"
  @scope "https://storage.azure.com/"

  def put!(:outbox, account_id, name, body) do
    %Req.Response{status: 201} =
      request!(:put, url(:outbox, account_id, name),
        body: body,
        headers: [{"x-ms-blob-type", "BlockBlob"}, {"content-type", "application/octet-stream"}]
      )

    :ok
  end

  def get(:inbox, account_id, name) do
    case request!(:get, url(:inbox, account_id, name), decode_body: false) do
      %Req.Response{status: 200, body: body} -> {:ok, body}
      %Req.Response{status: 404} -> {:error, :not_found}
    end
  end

  defp request!(method, url, opts) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    token = Portal.Azure.ManagedIdentity.access_token!(@scope)

    [
      method: method,
      url: url,
      headers: [
        {"authorization", "Bearer " <> token},
        {"x-ms-version", @api_version},
        {"x-ms-date", Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")}
      ]
    ]
    |> Keyword.merge(config[:req_opts] || [])
    |> Keyword.merge(opts, fn
      :headers, base, extra -> base ++ extra
      _key, _base, extra -> extra
    end)
    |> Req.request!()
  end

  defp url(box, account_id, name) do
    key = config_key(box)

    container_url =
      case Portal.Config.fetch_env!(:portal, key) do
        nil -> raise "#{key} is not configured"
        url -> String.trim_trailing(url, "/")
      end

    {:ok, account_id} = Ecto.UUID.cast(account_id)
    "#{container_url}/#{account_id}/#{name}"
  end

  defp config_key(:outbox), do: :region_transfer_outbox_url
  defp config_key(:inbox), do: :region_transfer_inbox_url
end
