defmodule FzHttp.ConnectivityChecksFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `FzHttp.ConnectivityChecks` context.
  """

  alias FzHttp.ConnectivityChecks

  @doc """
  Generate a connectivity_check.
  """
  def connectivity_check_fixture(attrs \\ %{}) do
    {:ok, connectivity_check} =
      attrs
      |> Enum.into(%{
        response_body: "some response_body",
        response_code: 142,
        response_headers: %{"Content-Type" => "text/plain"},
        url: "https://ping-dev.firez.one/0.0.0+git.0.deadbeef0"
      })
      |> ConnectivityChecks.create_connectivity_check()

    connectivity_check
  end
end
