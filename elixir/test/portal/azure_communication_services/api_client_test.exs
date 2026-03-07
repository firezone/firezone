defmodule Portal.AzureCommunicationServices.APIClientTest do
  use Portal.DataCase, async: true

  alias Portal.AzureCommunicationServices.APIClient

  test "fetch_delivery_state signs https requests without appending port 443 to host" do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      access_key: Base.encode64("01234567890123456789012345678901")
    )

    Portal.Config.put_env_override(APIClient,
      req_opts: [plug: {Req.Test, APIClient}, retry: false]
    )

    Req.Test.stub(APIClient, fn conn ->
      headers = Map.new(conn.req_headers)

      assert headers["host"] == "acs.example.com"
      assert headers["authorization"] =~ "HMAC-SHA256"
      assert headers["x-ms-content-sha256"] == Base.encode64(:crypto.hash(:sha256, ""))

      Req.Test.json(conn, %{"id" => "op-123", "status" => "Running"})
    end)

    assert {:ok, %{state: :processing, operation: %{"id" => "op-123"}}} =
             APIClient.fetch_delivery_state("op-123")
  end
end
