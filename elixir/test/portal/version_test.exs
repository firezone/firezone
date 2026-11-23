defmodule Portal.VersionTest do
  use ExUnit.Case, async: true
  import Portal.Version

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

  describe "client_supports_device_pools?/1" do
    test "uses component-specific minimum versions" do
      cases = [
        {"Mac OS/15.1.1 apple-client/1.5.16 (arm64; 24.1.0)", "1.5.15", "1.5.16"},
        {"Fedora/42.0.0 headless-client/1.5.9 (arm64; 24.1.0)", "1.5.8", "1.5.9"},
        {"Android/14 android-client/1.5.11 (arm64; 24.1.0)", "1.5.10", "1.5.11"},
        {"Windows/10.0.22631 gui-client/1.5.13 (arm64; 24.1.0)", "1.5.12", "1.5.13"}
      ]

      for {user_agent, unsupported_version, supported_version} <- cases do
        refute Portal.Version.client_supports_device_pools?(%Portal.Device{
                 type: :client,
                 last_seen_version: unsupported_version,
                 last_seen_user_agent: user_agent
               })

        assert Portal.Version.client_supports_device_pools?(%Portal.Device{
                 type: :client,
                 last_seen_version: supported_version,
                 last_seen_user_agent: user_agent
               })
      end
    end

    test "returns false for nil last_seen_version or last_seen_user_agent" do
      refute Portal.Version.client_supports_device_pools?(%Portal.Device{
               type: :client,
               last_seen_version: nil,
               last_seen_user_agent: "Android/14 android-client/1.5.11"
             })

      refute Portal.Version.client_supports_device_pools?(%Portal.Device{
               type: :client,
               last_seen_version: "1.5.11",
               last_seen_user_agent: nil
             })
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

  describe "supports_public_key_changed?/1" do
    test "uses component-specific minimum versions for clients" do
      cases = [
        {"Mac OS/15.1.1 apple-client/1.5.25 (arm64; 24.1.0)", "1.5.24", "1.5.25"},
        {"Fedora/42.0.0 headless-client/1.5.16 (arm64; 24.1.0)", "1.5.15", "1.5.16"},
        {"Android/14 android-client/1.5.19 (arm64; 24.1.0)", "1.5.18", "1.5.19"},
        {"Windows/10.0.22631 gui-client/1.5.21 (arm64; 24.1.0)", "1.5.20", "1.5.21"}
      ]

      for {user_agent, unsupported_version, supported_version} <- cases do
        refute Portal.Version.supports_public_key_changed?(%Portal.Device{
                 type: :client,
                 last_seen_version: unsupported_version,
                 last_seen_user_agent: user_agent
               })

        assert Portal.Version.supports_public_key_changed?(%Portal.Device{
                 type: :client,
                 last_seen_version: supported_version,
                 last_seen_user_agent: user_agent
               })
      end
    end

    test "uses the minimum version for gateways" do
      refute Portal.Version.supports_public_key_changed?(%Portal.Device{
               type: :gateway,
               last_seen_version: "1.6.4"
             })

      assert Portal.Version.supports_public_key_changed?(%Portal.Device{
               type: :gateway,
               last_seen_version: "1.6.5"
             })
    end
  end

  describe "devices without a type" do
    test "support every gated feature, whatever their user agent" do
      device = %Portal.Device{type: nil, last_seen_version: "1.7.0", last_seen_user_agent: "Linux/6.8 firezone/1.7.0"}

      assert client_supports_sites_payload?(device)
      refute resource_cannot_change_sites_on_client?(device)
      assert client_supports_device_pools?(device)
      assert supports_device_access?(device)
      assert supports_public_key_changed?(device)
    end
  end

  describe "legacy_proto_range/2" do
    test "a client speaks its own minor" do
      assert legacy_proto_range(:client, "1.5.3") == %{min: 5, max: 5}
    end

    test "a gateway speaks one minor either side" do
      assert legacy_proto_range(:gateway, "1.5.3") == %{min: 4, max: 6}
      assert legacy_proto_range(:gateway, "1.0.1") == %{min: 0, max: 1}
    end

    test "has no range without a version of major 1" do
      assert legacy_proto_range(:client, nil) == nil
      assert legacy_proto_range(:client, "not a version") == nil
      assert legacy_proto_range(:gateway, "2.0.0") == nil
    end
  end

  describe "declared_proto_range/1" do
    test "reads integers and integer strings" do
      assert declared_proto_range(%{"proto_min" => "5", "proto_max" => "7"}) == %{min: 5, max: 7}
      assert declared_proto_range(%{"proto_min" => 5, "proto_max" => 5}) == %{min: 5, max: 5}
    end

    test "refuses a missing, negative, inverted or malformed range" do
      assert declared_proto_range(%{}) == nil
      assert declared_proto_range(%{"proto_min" => "5"}) == nil
      assert declared_proto_range(%{"proto_min" => "-1", "proto_max" => "5"}) == nil
      assert declared_proto_range(%{"proto_min" => "7", "proto_max" => "5"}) == nil
      assert declared_proto_range(%{"proto_min" => "5x", "proto_max" => "7"}) == nil
    end
  end

  describe "proto_range_from_meta/1" do
    test "uses the range the meta carries" do
      assert proto_range_from_meta(%{type: :client, version: "1.5.0", proto_min: 3, proto_max: 5}) ==
               %{min: 3, max: 5}
    end

    test "falls back to the legacy range when the meta has none" do
      assert proto_range_from_meta(%{type: :gateway, version: "1.5.0"}) == %{min: 4, max: 6}
      assert proto_range_from_meta(%{type: :client, version: "1.5.0", proto_min: nil, proto_max: nil}) ==
               %{min: 5, max: 5}
    end
  end

  describe "compatible?/2" do
    test "is true when the ranges overlap" do
      assert compatible?(%{min: 5, max: 7}, %{min: 7, max: 8})
      refute compatible?(%{min: 5, max: 6}, %{min: 7, max: 8})
      refute compatible?(nil, %{min: 7, max: 8})
    end

    test "agrees with the old rule for every legacy client and gateway pair" do
      for client_minor <- 1..12, gateway_minor <- 0..12, patch <- [0, 9] do
        client = "1.#{client_minor}.#{patch}"
        gateway = "1.#{gateway_minor}.#{patch}"

        old =
          Version.match?(gateway, ">= 1.#{client_minor - 1}.0") and
            Version.match?(gateway, "< 1.#{client_minor + 2}.0")

        new = compatible?(legacy_proto_range(:client, client), legacy_proto_range(:gateway, gateway))

        assert old == new, "client #{client} and gateway #{gateway}"
      end
    end

    test "agrees with the old rule for every legacy client pair" do
      for a <- 0..12, b <- 0..12 do
        new = compatible?(legacy_proto_range(:client, "1.#{a}.0"), legacy_proto_range(:client, "1.#{b}.4"))
        assert new == (a == b), "clients 1.#{a} and 1.#{b}"
      end
    end
  end
end
