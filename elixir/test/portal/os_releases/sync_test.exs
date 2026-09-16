defmodule Portal.OSReleases.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  alias Portal.{OSRelease, OSReleases}

  @apple %{
    "PublicAssetSets" => %{
      "macOS" => [
        %{"ProductVersion" => "15.6.1", "SupportedDevices" => ["Mac16,1"]},
        %{"ProductVersion" => "15.5", "SupportedDevices" => ["Mac16,1"]},
        %{"ProductVersion" => "14.7.6", "SupportedDevices" => ["Mac14,2"]}
      ],
      "iOS" => [
        %{"ProductVersion" => "18.6", "SupportedDevices" => ["iPhone17,1", "iPad16,3"]},
        %{"ProductVersion" => "17.7.11", "SupportedDevices" => ["iPad7,1"]},
        %{"ProductVersion" => "9.6.4", "SupportedDevices" => ["Watch4,1"]}
      ]
    }
  }

  @kernel %{
    "releases" => [
      %{"moniker" => "mainline", "version" => "7.3-rc3", "iseol" => false},
      %{"moniker" => "stable", "version" => "7.2.4", "iseol" => false},
      %{"moniker" => "longterm", "version" => "6.12.34", "iseol" => false},
      %{"moniker" => "longterm", "version" => "5.10.230", "iseol" => true}
    ]
  }

  @products_page_1 %{
    "@odata.nextLink" => "https://graph.microsoft.com/beta/admin/windows/updates/products?$expand=revisions&$skiptoken=page2",
    "value" => [
      %{
        "name" => "Windows 11",
        "revisions" => [
          %{"osBuild" => %{"majorVersion" => 10, "minorVersion" => 0, "buildNumber" => 26100, "updateBuildRevision" => 4652}},
          %{"osBuild" => %{"majorVersion" => 10, "minorVersion" => 0, "buildNumber" => 26100, "updateBuildRevision" => 2894}},
          %{"osBuild" => %{"majorVersion" => 10, "minorVersion" => 0, "buildNumber" => 22631, "updateBuildRevision" => 5472}}
        ]
      }
    ]
  }

  @products_page_2 %{
    "value" => [
      %{
        "name" => "Windows Server 2022",
        "revisions" => [
          %{"osBuild" => %{"majorVersion" => 10, "minorVersion" => 0, "buildNumber" => 20348, "updateBuildRevision" => 3807}},
          %{"version" => "10.0.20348.3692"}
        ]
      }
    ]
  }

  defp stub_feeds(overrides \\ %{}) do
    Req.Test.stub(Portal.OSReleases.Sync, fn conn ->
      body =
        case conn.host do
          "gdmf.apple.com" -> @apple
          "www.kernel.org" -> @kernel
        end

      case Map.get(overrides, conn.host) do
        nil -> Req.Test.json(conn, body)
        status -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "boom"})
      end
    end)
  end

  defp stub_graph(token_status \\ 200) do
    Req.Test.stub(Portal.Microsoft.Graph.APIClient, fn conn ->
      case {conn.host, conn.request_path} do
        {"login.microsoftonline.com", "/test-firezone-tenant/oauth2/v2.0/token"} when token_status == 200 ->
          Req.Test.json(conn, %{"access_token" => "graph-token", "expires_in" => 3600})

        {"login.microsoftonline.com", _path} ->
          conn |> Plug.Conn.put_status(token_status) |> Req.Test.json(%{"error" => "invalid_client"})

        {"graph.microsoft.com", "/beta/admin/windows/updates/products"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer graph-token"]

          if conn.query_string =~ "skiptoken=page2" do
            Req.Test.json(conn, @products_page_2)
          else
            Req.Test.json(conn, @products_page_1)
          end
      end
    end)
  end

  defp releases(os) do
    OSRelease
    |> Repo.all()
    |> Enum.filter(&(&1.os == os))
    |> Map.new(&{&1.line, {&1.latest_version, &1.supported}})
  end

  test "stores the newest release per line from every source" do
    stub_feeds()
    stub_graph()

    assert :ok = perform_job(Portal.OSReleases.Sync, %{})

    assert releases(:macos) == %{"15" => {"15.6.1", true}, "14" => {"14.7.6", true}}
    assert releases(:ios) == %{"18" => {"18.6", true}, "17" => {"17.7.11", true}}, "watchOS builds are left out"
    assert releases(:linux) == %{"7.2" => {"7.2.4", true}, "6.12" => {"6.12.34", true}, "5.10" => {"5.10.230", false}}

    assert releases(:windows) == %{
             "10.0.26100" => {"10.0.26100.4652", true},
             "10.0.22631" => {"10.0.22631.5472", true},
             "10.0.20348" => {"10.0.20348.3807", true}
           }
  end

  test "a failing source is reported with its details and keeps that operating system's rows" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%OSRelease{os: :linux, line: "4.19", latest_version: "4.19.300", supported: true, fetched_at: now})
    Repo.insert!(%OSRelease{os: :windows, line: "10.0.19045", latest_version: "10.0.19045.6093", supported: true, fetched_at: now})
    Repo.insert!(%OSRelease{os: :macos, line: "12", latest_version: "12.7.6", supported: true, fetched_at: now})

    stub_feeds(%{"www.kernel.org" => 500})
    stub_graph(401)

    log = capture_log(fn -> assert :ok = perform_job(Portal.OSReleases.Sync, %{}) end)

    assert log =~ "Can't fetch OS releases for linux: url=https://www.kernel.org/releases.json status=500"
    assert log =~ "Can't fetch OS releases for windows: step=token tenant_id=test-firezone-tenant status=401"
    assert log =~ "invalid_client"

    assert releases(:linux) == %{"4.19" => {"4.19.300", true}}
    assert releases(:windows) == %{"10.0.19045" => {"10.0.19045.6093", true}}
    refute Map.has_key?(releases(:macos), "12"), "a line that left a healthy feed is dropped"
    assert Map.has_key?(releases(:macos), "15")
  end

  test "the mirror is asked to reload on this node" do
    stub_feeds()
    stub_graph()
    assert :ok = perform_job(Portal.OSReleases.Sync, %{})
    assert Process.alive?(Process.whereis(OSReleases))
  end
end
