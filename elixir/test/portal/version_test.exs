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

    test "nil version returns false" do
      session = %Portal.ClientSession{version: nil}
      refute Portal.Version.resource_cannot_change_sites_on_client?(session)
    end
  end

  describe "resource_cannot_change_sites_on_client?/1 with Client" do
    test "client with nil latest_session returns false" do
      client = %Portal.Client{latest_session: nil}
      refute Portal.Version.resource_cannot_change_sites_on_client?(client)
    end

    test "client delegates to session" do
      client = %Portal.Client{
        latest_session: %Portal.ClientSession{version: "1.5.7", user_agent: "Mac OS X"}
      }

      assert Portal.Version.resource_cannot_change_sites_on_client?(client)
    end
  end
end
