defmodule PortalWeb.LiveHooks.PutDynamicRepoTest do
  use ExUnit.Case, async: true

  alias PortalWeb.LiveHooks.PutDynamicRepo

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      endpoint: PortalWeb.Endpoint,
      router: PortalWeb.Router
    }
  end

  describe "on_mount/4" do
    test "continues with socket unchanged" do
      socket = build_socket()

      assert {:cont, ^socket} = PutDynamicRepo.on_mount(:default, %{}, %{}, socket)
    end
  end
end
