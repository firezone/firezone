defmodule Portal.VersionTest do
  use ExUnit.Case, async: true

  describe "fetch_version/1" do
    test "can decode linux headless-client version" do
      assert Portal.Version.fetch_version("Fedora/42.0.0 headless-client/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "can decode windows headless-client version" do
      assert Portal.Version.fetch_version(
               "Windows/10.0.22631 headless-client/1.4.5 (arm64; 24.1.0)"
             ) ==
               {:ok, "1.4.5"}
    end

    test "can decode apple-client version" do
      assert Portal.Version.fetch_version("Mac OS/15.1.1 apple-client/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "can decode android-client version" do
      assert Portal.Version.fetch_version("Android/14 android-client/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "can decode windows gui-client version" do
      assert Portal.Version.fetch_version("Windows/10.0.22631 gui-client/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "can decode linux gui-client version" do
      assert Portal.Version.fetch_version("Fedora/42.0.0 gui-client/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "can decode gateway version" do
      assert Portal.Version.fetch_version("Fedora/42.0.0 gateway/1.4.5 (arm64; 24.1.0)") ==
               {:ok, "1.4.5"}
    end

    test "returns error for an unparsable user agent" do
      assert Portal.Version.fetch_version("not a user agent") == {:error, :invalid_user_agent}
    end

    test "returns error for a missing user agent" do
      assert Portal.Version.fetch_version(nil) == {:error, :invalid_user_agent}
    end
  end

  describe "client_supports_sites_payload?/1" do
    test "uses component-specific minimum versions" do
      cases = [
        {"Mac OS/15.1.1 apple-client/1.5.11 (arm64; 24.1.0)", "1.5.10", "1.5.11"},
        {"Fedora/42.0.0 headless-client/1.5.6 (arm64; 24.1.0)", "1.5.5", "1.5.6"},
        {"Android/14 android-client/1.5.8 (arm64; 24.1.0)", "1.5.7", "1.5.8"},
        {"Windows/10.0.22631 gui-client/1.5.10 (arm64; 24.1.0)", "1.5.9", "1.5.10"}
      ]

      for {user_agent, unsupported_version, supported_version} <- cases do
        refute Portal.Version.client_supports_sites_payload?(%Portal.Device{
                 type: :client,
                 last_seen_version: unsupported_version,
                 last_seen_user_agent: user_agent
               })

        assert Portal.Version.client_supports_sites_payload?(%Portal.Device{
                 type: :client,
                 last_seen_version: supported_version,
                 last_seen_user_agent: user_agent
               })
      end
    end

    test "returns false for nil or invalid versions" do
      refute Portal.Version.client_supports_sites_payload?(%Portal.Device{
               type: :client,
               last_seen_version: nil,
               last_seen_user_agent: "Windows/10.0.22631 gui-client/1.5.10"
             })

      refute Portal.Version.client_supports_sites_payload?(%Portal.Device{
               type: :client,
               last_seen_version: "not-a-version",
               last_seen_user_agent: "Windows/10.0.22631 gui-client/not-a-version"
             })
    end
  end

  describe "resource_cannot_change_sites_on_client?/1" do
    test "apple client below version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.7",
        last_seen_user_agent: "Mac OS X"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "apple client at version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.8",
        last_seen_user_agent: "Mac OS X"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "apple client above version can change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.9",
        last_seen_user_agent: "Mac OS X"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client below version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.3",
        last_seen_user_agent: "Android"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client at version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.4",
        last_seen_user_agent: "Android"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client above version can change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.5",
        last_seen_user_agent: "Android"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client below version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.7",
        last_seen_user_agent: "Windows"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client at version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.8",
        last_seen_user_agent: "Windows"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client above version can change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.9",
        last_seen_user_agent: "Windows"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client below version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.3",
        last_seen_user_agent: "Fedora/42.0.0 headless-client/1.5.3 (arm64; 24.1.0)"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client at version cannot change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.4",
        last_seen_user_agent: "Fedora/42.0.0 headless-client/1.5.4 (arm64; 24.1.0)"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client above version can change sites" do
      client = %Portal.Device{
        type: :client,
        last_seen_version: "1.5.5",
        last_seen_user_agent: "Fedora/42.0.0 headless-client/1.5.5 (arm64; 24.1.0)"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "nil last_seen_version returns false" do
      client = %Portal.Device{type: :client, last_seen_version: nil}
      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end
  end

  describe "supports_device_access?/1" do
    test "uses component-specific minimum versions" do
      cases = [
        {"Mac OS/15.1.1 apple-client/1.5.14 (arm64; 24.1.0)", "1.5.13", "1.5.14"},
        {"Fedora/42.0.0 headless-client/1.5.7 (arm64; 24.1.0)", "1.5.6", "1.5.7"},
        {"Android/14 android-client/1.5.9 (arm64; 24.1.0)", "1.5.8", "1.5.9"},
        {"Windows/10.0.22631 gui-client/1.5.11 (arm64; 24.1.0)", "1.5.10", "1.5.11"}
      ]

      for {user_agent, unsupported_version, supported_version} <- cases do
        refute Portal.Version.supports_device_access?(%Portal.Device{
                 type: :client,
                 last_seen_version: unsupported_version,
                 last_seen_user_agent: user_agent
               })

        assert Portal.Version.supports_device_access?(%Portal.Device{
                 type: :client,
                 last_seen_version: supported_version,
                 last_seen_user_agent: user_agent
               })
      end
    end

    test "returns false for nil last_seen_version or last_seen_user_agent" do
      refute Portal.Version.supports_device_access?(%Portal.Device{
               type: :client,
               last_seen_version: nil,
               last_seen_user_agent: "Mac OS/14 apple-client/1.5.14"
             })

      refute Portal.Version.supports_device_access?(%Portal.Device{
               type: :client,
               last_seen_version: "1.5.14",
               last_seen_user_agent: nil
             })
    end
  end

  describe "supports_device_access?/2" do
    test "accepts user_agent and version directly" do
      assert Portal.Version.supports_device_access?(
               "Mac OS/14 apple-client/1.5.14",
               "1.5.14"
             )

      refute Portal.Version.supports_device_access?(
               "Mac OS/14 apple-client/1.5.13",
               "1.5.13"
             )
    end

    test "returns false when either argument is nil" do
      refute Portal.Version.supports_device_access?(nil, "1.5.14")
      refute Portal.Version.supports_device_access?("apple-client/1.5.14", nil)
    end
  end
end
