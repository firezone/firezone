defmodule Portal.ComponentVersionsTest do
  use ExUnit.Case, async: true
  import Portal.ComponentVersions
  alias Portal.ComponentVersions
  alias Portal.Mocks.FirezoneWebsite

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
        Portal.Config.get_env(:portal, ComponentVersions)
        |> Keyword.merge(
          fetch_from_url: true,
          firezone_releases_url: "http://localhost:#{bypass.port}/api/releases"
        )

      Portal.Config.put_env_override(ComponentVersions, new_config)

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
        Portal.Config.get_env(:portal, ComponentVersions)
        |> Keyword.merge(versions: Enum.into(versions, []))

      Portal.Config.put_env_override(ComponentVersions, new_config)

      assert fetch_versions() == {:ok, Enum.into(versions, [])}
    end
  end

  describe "get_component_type/1" do
    test "returns :headless for service_account actors" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :service_account},
        latest_session: nil
      }

      assert get_component_type(client) == :headless
    end

    test "returns :apple for Mac OS user agent" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :account_user},
        latest_session: %{user_agent: "Mac OS/14.0"}
      }

      assert get_component_type(client) == :apple
    end

    test "returns :apple for iOS user agent" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :account_user},
        latest_session: %{user_agent: "iOS/17.0"}
      }

      assert get_component_type(client) == :apple
    end

    test "returns :android for Android user agent" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :account_user},
        latest_session: %{user_agent: "Android/14"}
      }

      assert get_component_type(client) == :android
    end

    test "returns :gui for other user agents" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :account_user},
        latest_session: %{user_agent: "Windows/10"}
      }

      assert get_component_type(client) == :gui
    end

    test "returns :gui when latest_session is nil" do
      client = %Portal.Client{
        actor: %Portal.Actor{type: :account_user},
        latest_session: nil
      }

      assert get_component_type(client) == :gui
    end
  end
end
