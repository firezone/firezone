defmodule PortalWeb.RateLimitTest do
  use PortalWeb.ConnCase, async: false

  setup do
    previous_config = Application.get_env(:portal, PortalWeb.RateLimit)

    Application.put_env(:portal, PortalWeb.RateLimit,
      refill_rate: 1,
      capacity: PortalWeb.RateLimit.default_cost()
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:portal, PortalWeb.RateLimit, previous_config)
      else
        Application.delete_env(:portal, PortalWeb.RateLimit)
      end
    end)

    :ok
  end

  test "limits repeated requests from the same client IP", %{conn: conn} do
    ip = unique_ip()

    first_resp =
      conn
      |> put_ip(ip)
      |> get("/browser/config.xml")

    assert response(first_resp, 200)

    second_resp =
      conn
      |> recycle()
      |> put_ip(ip)
      |> get("/browser/config.xml")

    assert response(second_resp, 429) == "Too Many Requests"
    assert [retry_after] = get_resp_header(second_resp, "retry-after")
    assert String.to_integer(retry_after) >= 1
  end

  defp put_ip(conn, ip) do
    %{conn | remote_ip: ip}
  end

  defp unique_ip do
    {:rand.uniform(255), :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end
end
