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
  end

  describe "resource_cannot_change_sites_on_client?/1" do
    test "apple client below version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.7",
        last_seen_user_agent: "Mac OS X"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "apple client at version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.8",
        last_seen_user_agent: "Mac OS X"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "apple client above version can change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.9",
        last_seen_user_agent: "Mac OS X"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client below version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.3",
        last_seen_user_agent: "Android"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client at version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.4",
        last_seen_user_agent: "Android"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "android client above version can change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.5",
        last_seen_user_agent: "Android"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client below version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.3",
        actor: %Portal.Actor{type: :service_account}
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client at version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.4",
        actor: %Portal.Actor{type: :service_account}
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "headless client above version can change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.5",
        actor: %Portal.Actor{type: :service_account}
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client below version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.7",
        last_seen_user_agent: "Windows"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client at version cannot change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.8",
        last_seen_user_agent: "Windows"
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "gui client above version can change sites" do
      client = %Portal.Client{
        last_seen_version: "1.5.9",
        last_seen_user_agent: "Windows"
      }

      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end
  end
end
