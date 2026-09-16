defmodule Portal.OSReleases.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

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

  @windows [
    %{"cycle" => "11-24h2-e", "latest" => "10.0.26100.4652", "eol" => "2029-10-09"},
    %{"cycle" => "11-24h2-w", "latest" => "10.0.26100.4000", "eol" => "2026-01-01"},
    %{"cycle" => "10-22h2", "latest" => "10.0.19045.6093", "eol" => "2025-10-14"},
    %{"cycle" => "11-26h1-e", "latest" => "10.0.28000", "eol" => false}
  ]

  @windows_server [
    %{"cycle" => "2025", "latest" => "10.0.26100", "eol" => "2034-11-14"},
    %{"cycle" => "2022", "latest" => "10.0.20348", "eol" => "2031-10-14"},
    %{"cycle" => "2012-r2", "latest" => "6.3.9600", "eol" => "2023-10-10"}
  ]


  defp stub(overrides \\ %{}) do
    Req.Test.stub(Portal.OSReleases.Sync, fn conn ->
      body =
        case {conn.host, conn.request_path} do
          {"gdmf.apple.com", _path} -> @apple
          {"www.kernel.org", _path} -> @kernel
          {_host, "/api/windows.json"} -> @windows
          {_host, "/api/windows-server.json"} -> @windows_server
        end

      case Map.get(overrides, conn.host) do
        nil -> Req.Test.json(conn, body)
        status -> Plug.Conn.send_resp(conn, status, "nope")
      end
    end)
  end

  defp releases(os) do
    OSRelease
    |> Repo.all()
    |> Enum.filter(&(&1.os == os))
    |> Map.new(&{&1.line, {&1.latest_version, &1.supported}})
  end

  test "stores the newest release per line from every feed" do
    stub()

    assert :ok = perform_job(Portal.OSReleases.Sync, %{})

    assert releases(:macos) == %{"15" => {"15.6.1", true}, "14" => {"14.7.6", true}}
    assert releases(:ios) == %{"18" => {"18.6", true}, "17" => {"17.7.11", true}}, "watchOS builds are left out"
    assert releases(:linux) == %{"7.2" => {"7.2.4", true}, "6.12" => {"6.12.34", true}, "5.10" => {"5.10.230", false}}

    assert releases(:windows) == %{
             "10.0.26100" => {"10.0.26100.4652", true},
             "10.0.19045" => {"10.0.19045.6093", false},
             "10.0.28000" => {"10.0.28000", true},
             "10.0.20348" => {"10.0.20348", true}
           }
  end

  test "a failing feed keeps that operating system's rows and drops lines that left a feed" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    Repo.insert!(%OSRelease{os: :linux, line: "4.19", latest_version: "4.19.300", supported: true, fetched_at: now})
    Repo.insert!(%OSRelease{os: :macos, line: "12", latest_version: "12.7.6", supported: true, fetched_at: now})

    stub(%{"www.kernel.org" => 500})

    assert :ok = perform_job(Portal.OSReleases.Sync, %{})

    assert releases(:linux) == %{"4.19" => {"4.19.300", true}}
    refute Map.has_key?(releases(:macos), "12")
    assert Map.has_key?(releases(:macos), "15")
  end

  test "the mirror is asked to reload on this node" do
    stub()
    assert :ok = perform_job(Portal.OSReleases.Sync, %{})
    assert Process.alive?(Process.whereis(OSReleases))
  end
end
