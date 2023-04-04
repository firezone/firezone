defmodule Web.Plug.PathPrefix do
  @moduledoc """
  This Plug removes prefix from Plug.Conn path fields which allows to run Firezone
  under non root directory without recompiling it.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: request_path} = conn, _opts) do
    if path_prefix = get_path_prefix() do
      request_path_info = String.split(request_path, "/")
      trim_prefix(conn, request_path_info, path_prefix)
    else
      conn
    end
  end

  defp get_path_prefix do
    case Domain.Config.fetch_env!(:web, :path_prefix) do
      "/" -> nil
      nil -> nil
      prefix when is_binary(prefix) -> String.trim(prefix, "/")
    end
  end

  defp trim_prefix(
         %Plug.Conn{path_info: [prefix | path_info]} = conn,
         ["", prefix | request_path_info],
         prefix
       ) do
    %{conn | path_info: path_info, request_path: Enum.join([""] ++ request_path_info, "/")}
  end

  defp trim_prefix(%Plug.Conn{} = conn, _request_path_info, prefix) do
    Phoenix.Controller.redirect(conn, to: "/" <> Path.join(prefix, conn.request_path))
  end
end
