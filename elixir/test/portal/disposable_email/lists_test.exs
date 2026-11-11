defmodule Portal.DisposableEmail.ListsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Portal.DisposableEmailHelpers
  alias Portal.DisposableEmail.Lists

  @url "https://lists.example.test/confirmed.txt"

  describe "parse/1" do
    test "returns lowercased domains, skipping comments and blank lines" do
      body = "# Confirmed\r\nFLDubai.com\n\n  mail.tm.  \n# trailing comment\n"

      assert Lists.parse(body) == {:ok, MapSet.new(["fldubai.com", "mail.tm"])}
    end

    test "returns an empty set for an empty list" do
      assert Lists.parse("# nothing yet\n") == {:ok, MapSet.new()}
    end

    test "rejects the whole list when a line is not a domain" do
      assert Lists.parse("fldubai.com\n<html>\nmail.tm") == {:error, {:invalid_line, 2}}
      assert Lists.parse("localhost") == {:error, {:invalid_line, 1}}
      assert Lists.parse("user@fldubai.com") == {:error, {:invalid_line, 1}}
    end

    test "rejects invalid UTF-8" do
      assert Lists.parse(<<0xFF, 0xFE>>) == {:error, :invalid_encoding}
    end

    test "rejects lists over 10 MB" do
      assert Lists.parse(String.duplicate("a", 10 * 1024 * 1024 + 1)) == {:error, :too_large}
    end
  end

  describe "fetch/3 with file:// URLs" do
    @describetag :tmp_dir

    test "reads the file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "confirmed.txt")
      File.write!(path, "fldubai.com\n")

      assert Lists.fetch("file://" <> path, nil) == {:ok, "fldubai.com\n", nil}
    end

    test "returns an error when the file is missing", %{tmp_dir: tmp_dir} do
      assert Lists.fetch("file://" <> Path.join(tmp_dir, "missing.txt"), nil) == {:error, :enoent}
    end

    test "rejects files over 10 MB without reading them", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large.txt")
      File.write!(path, String.duplicate("a", 10 * 1024 * 1024 + 1))

      assert Lists.fetch("file://" <> path, nil) == {:error, :too_large}
    end

    test "rejects a host, which would make the path relative" do
      assert Lists.fetch("file://priv/confirmed.txt", nil) == {:error, :unsupported_url}
    end
  end

  describe "fetch/3 with https:// URLs" do
    test "returns the body and the ETag" do
      Req.Test.stub(Lists, fn conn ->
        assert conn.request_path == "/confirmed.txt"
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_header("etag", "\"v1\"")
        |> Plug.Conn.send_resp(200, "fldubai.com\n")
      end)

      assert Lists.fetch(@url, nil, req_opts()) == {:ok, "fldubai.com\n", "\"v1\""}
    end

    test "sends the ETag and returns :not_modified on 304" do
      Req.Test.stub(Lists, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == ["\"v1\""]
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert Lists.fetch(@url, "\"v1\"", req_opts()) == :not_modified
    end

    test "returns an error on other statuses" do
      Req.Test.stub(Lists, &Plug.Conn.send_resp(&1, 403, "AuthorizationPermissionMismatch"))

      assert Lists.fetch(@url, nil, req_opts()) == {:error, {:unexpected_status, 403}}
    end

    test "returns an error on transport errors" do
      Req.Test.stub(Lists, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Lists.fetch(@url, nil, req_opts())
    end

    test "authenticates with the Azure managed identity" do
      Req.Test.stub(Portal.Azure.ManagedIdentity, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["resource"] == "https://storage.azure.com/"
        Req.Test.json(conn, %{"access_token" => "storage-token", "expires_on" => "4102444800"})
      end)

      Req.Test.stub(Lists, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer storage-token"]
        assert Plug.Conn.get_req_header(conn, "x-ms-version") == ["2020-12-06"]
        Plug.Conn.send_resp(conn, 200, "fldubai.com\n")
      end)

      assert {:ok, "fldubai.com\n", nil} = Lists.fetch(@url, nil, req_opts(azure_managed_identity: true))
    end

    test "returns an error when the managed identity token cannot be fetched" do
      Req.Test.stub(Portal.Azure.ManagedIdentity, &Plug.Conn.send_resp(&1, 500, "IMDS unavailable"))
      Req.Test.stub(Lists, fn _conn -> flunk("list requested without a token") end)

      assert {:error, {:managed_identity, _exception}} =
               Lists.fetch(@url, nil, req_opts(azure_managed_identity: true))
    end

    test "rejects other schemes" do
      assert Lists.fetch("http://lists.example.test/confirmed.txt", nil) == {:error, :unsupported_url}
      assert Lists.fetch("ftp://lists.example.test/confirmed.txt", nil) == {:error, :unsupported_url}
    end
  end

  describe "the process" do
    test "loads the lists on start" do
      {name, _paths} = use_disposable_email_lists(confirmed: ["fldubai.com"], suspected: ["mailinator.com"])

      assert Lists.reload(name) == %{confirmed: :ok, suspected: :ok}
      assert Lists.domains(:confirmed, name) == MapSet.new(["fldubai.com"])
      assert Lists.domains(:suspected, name) == MapSet.new(["mailinator.com"])
    end

    test "reports lists that are not configured as empty" do
      {name, _paths} = use_disposable_email_lists(confirmed: ["fldubai.com"])

      assert Lists.reload(name) == %{confirmed: :ok, suspected: :not_configured}
      assert Lists.domains(:suspected, name) == MapSet.new()
    end

    test "picks up changes on reload" do
      {name, paths} = use_disposable_email_lists(confirmed: ["fldubai.com"])
      File.write!(paths.confirmed, "fldubai.com\nmail.tm\n")

      assert %{confirmed: :ok} = Lists.reload(name)
      assert Lists.domains(:confirmed, name) == MapSet.new(["fldubai.com", "mail.tm"])
    end

    test "keeps the previous list when the new one is malformed" do
      {name, paths} = use_disposable_email_lists(confirmed: ["fldubai.com"])
      File.write!(paths.confirmed, "<html>Not Found</html>")

      log =
        capture_log(fn ->
          assert %{confirmed: {:error, {:invalid_line, 1}}} = Lists.reload(name)
        end)

      assert log =~ "Failed to load disposable email domain list, keeping the previous one"
      assert Lists.domains(:confirmed, name) == MapSet.new(["fldubai.com"])
    end

    test "keeps the previous list when the file disappears" do
      {name, paths} = use_disposable_email_lists(confirmed: ["fldubai.com"])
      File.rm!(paths.confirmed)

      capture_log(fn -> assert %{confirmed: {:error, :enoent}} = Lists.reload(name) end)
      assert Lists.domains(:confirmed, name) == MapSet.new(["fldubai.com"])
    end

    test "starts with an empty list when the first load fails" do
      log =
        capture_log(fn ->
          {name, _paths} =
            use_disposable_email_lists([], confirmed_url: "file:///nonexistent/disposable/confirmed.txt")

          assert %{confirmed: {:error, :enoent}} = Lists.reload(name)
          assert Lists.domains(:confirmed, name) == MapSet.new()
        end)

      assert log =~ "Failed to load disposable email domain list"
    end

    test "refreshes on the refresh interval" do
      {name, paths} = use_disposable_email_lists([confirmed: ["fldubai.com"]], refresh_interval: 10)
      File.write!(paths.confirmed, "mail.tm\n")

      wait_until(fn -> Lists.domains(:confirmed, name) == MapSet.new(["mail.tm"]) end)
    end
  end

  defp req_opts(opts \\ []) do
    Keyword.put(opts, :req_opts, plug: {Req.Test, Lists}, retry: false)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    unless fun.() do
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
