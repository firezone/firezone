# The user-agents in this file have been taken from the production DB.

defmodule API.Gateway.Views.ClientTest do
  use ExUnit.Case, async: true
  alias Domain.Clients

  describe "render/2" do
    test "parses_linux_headless_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "Ubuntu/22.4.0 headless-client/1.5.4 (x86_64; 6.8.0-1036-azure)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "Ubuntu"
      assert view.device_os_version == "22.4.0"
      assert view.version == "1.5.4"
    end

    test "parses_macos_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "Mac OS/15.4.1 apple-client/1.5.8 (arm64; 24.4.0)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "Mac OS"
      assert view.device_os_version == "15.4.1"
      assert view.version == "1.5.8"
    end

    test "parses_android_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "Android/12 android-client/1.5.2 (4.14.180-perf+)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "Android"
      assert view.device_os_version == "12"
      assert view.version == "1.5.2"
    end

    test "parses_windows_gui_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "Windows/10.0.26200 gui-client/1.5.8 (x86_64)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "Windows"
      assert view.device_os_version == "10.0.26200"
      assert view.version == "1.5.8"
    end

    test "parses_ios_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "iOS/26.0.1 apple-client/1.5.8 (25.0.0)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "iOS"
      assert view.device_os_version == "26.0.1"
      assert view.version == "1.5.8"
    end

    test "parses_pop_os_user_agent" do
      client = %Clients.Client{
        last_seen_user_agent: "Pop!_OS/24.4.0 gui-client/1.5.8 (x86_64; 6.16.3-76061603-generic)"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "Pop!_OS"
      assert view.device_os_version == "24.4.0"
      assert view.version == "1.5.8"
    end

    test "parses_user_agent_without_additional_data" do
      client = %Clients.Client{
        last_seen_user_agent: "iOS/26.0.1 apple-client/1.5.8"
      }

      view = API.Gateway.Views.Client.render(client, "")

      assert view.device_os_name == "iOS"
      assert view.device_os_version == "26.0.1"
      assert view.version == "1.5.8"
    end
  end
end
