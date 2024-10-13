defmodule Domain.ComponentVersionsTest do
  use ExUnit.Case, async: true
  import Domain.ComponentVersions
  alias Domain.ComponentVersions
  alias Domain.Mocks.FirezoneWebsite

  setup do
    bypass = Bypass.open()
    %{bypass: bypass}
  end

  describe "fetch_versions/0" do
    test "fetches versions from url", %{bypass: bypass} do
      versions = %{
        apple: "1.1.1",
        android: "1.1.1",
        gateway: "1.2.3",
        gui: "1.1.1",
        headless: "1.1.1"
      }

      FirezoneWebsite.mock_versions_endpoint(bypass, versions)

      new_config =
        Domain.Config.get_env(:domain, ComponentVersions)
        |> Keyword.merge(
          fetch_from_url: true,
          firezone_releases_url: "http://localhost:#{bypass.port}/api/releases"
        )

      Domain.Config.put_env_override(ComponentVersions, new_config)

      assert fetch_versions() == {:ok, Enum.into(versions, [])}
    end

    test "fetches versions from config" do
      versions = %{
        apple: "2.1.1",
        android: "2.1.1",
        gateway: "2.2.3",
        gui: "2.1.1",
        headless: "2.1.1"
      }

      new_config =
        Domain.Config.get_env(:domain, ComponentVersions)
        |> Keyword.merge(versions: Enum.into(versions, []))

      Domain.Config.put_env_override(ComponentVersions, new_config)

      assert fetch_versions() == {:ok, Enum.into(versions, [])}
    end
  end
end
