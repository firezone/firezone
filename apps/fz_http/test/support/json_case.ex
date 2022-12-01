defmodule FzHttpWeb.APICase do
  @moduledoc """
  Helpers for JSON tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use FzHttpWeb.ConnCase, async: true

      setup %{admin_conn: conn} do
        {:ok, conn: put_req_header(conn, "accept", "application/json")}
      end
    end
  end
end
