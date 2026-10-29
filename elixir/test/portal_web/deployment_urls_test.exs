defmodule PortalWeb.DeploymentURLsTest do
  use ExUnit.Case, async: true

  alias PortalWeb.DeploymentURLs

  describe "api_url/0" do
    test "returns the override when one is set" do
      Portal.Config.put_env_override(:api_url_override, "wss://host.docker.internal:13001/")
      Portal.Config.put_env_override(:api_external_url, "https://eu.api.firezone.dev/")

      assert DeploymentURLs.api_url() == "wss://host.docker.internal:13001/"
    end
  end

  describe "auth_url/0" do
    test "is nil for the default web URL" do
      Portal.Config.put_env_override(:web_external_url, "https://app.firezone.dev/")

      assert DeploymentURLs.auth_url() == nil
    end

    test "returns any other web URL" do
      Portal.Config.put_env_override(:web_external_url, "https://eu.app.firezone.dev/")

      assert DeploymentURLs.auth_url() == "https://eu.app.firezone.dev/"
    end
  end
end
