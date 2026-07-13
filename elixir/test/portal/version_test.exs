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
        refute Portal.Version.client_supports_sites_payload?(%Portal.ClientSession{
                 version: unsupported_version,
                 user_agent: user_agent
               })

        assert Portal.Version.client_supports_sites_payload?(%Portal.ClientSession{
                 version: supported_version,
                 user_agent: user_agent
               })
      end
    end

    test "returns false for nil or invalid versions" do
      refute Portal.Version.client_supports_sites_payload?(%Portal.ClientSession{
               version: nil,
               user_agent: "Windows/10.0.22631 gui-client/1.5.10"
             })

      refute Portal.Version.client_supports_sites_payload?(%Portal.ClientSession{
               version: "not-a-version",
               user_agent: "Windows/10.0.22631 gui-client/not-a-version"
             })
    end
  end

  describe "client_supports_authorization_messages?/1" do
    test "uses the current component versions as the cutover" do
      cases = [
        {"apple-client", "1.5.18", "1.5.19"},
        {"headless-client", "1.5.10", "1.5.11"},
        {"android-client", "1.5.12", "1.5.13"},
        {"gui-client", "1.5.15", "1.5.16"}
      ]

      for {component, old_version, cutover_version} <- cases do
        refute Portal.Version.client_supports_authorization_messages?(%Portal.ClientSession{
                 version: old_version,
                 user_agent: "Test/1.0 #{component}/#{old_version}"
               })

        assert Portal.Version.client_supports_authorization_messages?(%Portal.ClientSession{
                 version: cutover_version,
                 user_agent: "Test/1.0 #{component}/#{cutover_version}"
               })
      end
    end
  end

  describe "gateway_supports_authorization_messages?/1" do
    test "cuts over at the current gateway version" do
      refute Portal.Version.gateway_supports_authorization_messages?(%Portal.GatewaySession{
               version: "1.5.2"
             })

      assert Portal.Version.gateway_supports_authorization_messages?(%Portal.GatewaySession{
               version: "1.5.3"
             })
    end
  end

  describe "resource_cannot_change_sites_on_client?/1 with ClientSession" do
    test "apple session below version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.7", user_agent: "Mac OS X"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "apple session at version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.8", user_agent: "Mac OS X"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "apple session above version can change sites" do
      session = %Portal.ClientSession{version: "1.5.9", user_agent: "Mac OS X"}
      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "android session below version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.3", user_agent: "Android"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "android session at version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.4", user_agent: "Android"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "android session above version can change sites" do
      session = %Portal.ClientSession{version: "1.5.5", user_agent: "Android"}
      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "gui session below version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.7", user_agent: "Windows"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "gui session at version cannot change sites" do
      session = %Portal.ClientSession{version: "1.5.8", user_agent: "Windows"}
      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "gui session above version can change sites" do
      session = %Portal.ClientSession{version: "1.5.9", user_agent: "Windows"}
      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "headless session below version cannot change sites" do
      session = %Portal.ClientSession{
        version: "1.5.3",
        user_agent: "Fedora/42.0.0 headless-client/1.5.3 (arm64; 24.1.0)"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "headless session at version cannot change sites" do
      session = %Portal.ClientSession{
        version: "1.5.4",
        user_agent: "Fedora/42.0.0 headless-client/1.5.4 (arm64; 24.1.0)"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "headless session above version can change sites" do
      session = %Portal.ClientSession{
        version: "1.5.5",
        user_agent: "Fedora/42.0.0 headless-client/1.5.5 (arm64; 24.1.0)"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end

    test "nil version returns false" do
      session = %Portal.ClientSession{version: nil}
      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end
  end

  describe "resource_cannot_change_sites_on_client?/1 with Device" do
    test "client with nil latest_session returns false" do
      client = %Portal.Device{type: :client, latest_session: nil}
      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "client delegates to session" do
      client = %Portal.Device{
        type: :client,
        latest_session: %Portal.ClientSession{version: "1.5.7", user_agent: "Mac OS X"}
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
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
        refute Portal.Version.supports_device_access?(%Portal.ClientSession{
                 version: unsupported_version,
                 user_agent: user_agent
               })

        assert Portal.Version.supports_device_access?(%Portal.ClientSession{
                 version: supported_version,
                 user_agent: user_agent
               })
      end
    end

    test "returns false for nil version or user_agent" do
      refute Portal.Version.supports_device_access?(%Portal.ClientSession{
               version: nil,
               user_agent: "Mac OS/14 apple-client/1.5.14"
             })

      refute Portal.Version.supports_device_access?(%Portal.ClientSession{
               version: "1.5.14",
               user_agent: nil
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
