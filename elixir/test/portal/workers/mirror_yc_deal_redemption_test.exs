defmodule Portal.Workers.MirrorYCDealRedemptionTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import ExUnit.CaptureLog

  alias Portal.Workers.MirrorYCDealRedemption

  @args %{"body" => ~s({"id":1,"deal_id":2417}), "signature" => "abc123"}

  setup do
    Portal.Config.put_env_override(:portal, :yc_deal_mirror_url, "https://eu.example.com/yc")
    :ok
  end

  test "sends the body and signature as YC sent them, without the email" do
    test_pid = self()

    Req.Test.stub(MirrorYCDealRedemption, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:mirror, conn, body})
      Req.Test.json(conn, %{"message" => "ok"})
    end)

    assert :ok = perform_job(MirrorYCDealRedemption, @args)

    assert_received {:mirror, conn, body}
    assert body == @args["body"]
    assert conn.host == "eu.example.com"
    assert conn.request_path == "/yc"
    assert conn.query_string == "skip_email=true"
    assert Plug.Conn.get_req_header(conn, "x-yc-signature") == ["abc123"]
  end

  test "fails so Oban retries when the other portal rejects it" do
    Req.Test.stub(MirrorYCDealRedemption, &Plug.Conn.send_resp(&1, 502, "{}"))

    capture_log(fn ->
      assert {:error, {:unexpected_status, 502}} = perform_job(MirrorYCDealRedemption, @args)
    end)
  end

  test "cancels when no other portal is set" do
    Portal.Config.put_env_override(:portal, :yc_deal_mirror_url, nil)

    assert {:cancel, :no_mirror_url} = perform_job(MirrorYCDealRedemption, @args)
  end
end
