defmodule Portal.Conn do
  @moduledoc """
  Keeps the current `Plug.Conn` attached to an exception.

  Phoenix renders an exception with the conn it held before the failing plug or
  action ran. Once that code has read the request body, the earlier conn is
  stale and Bandit refuses to send a response on it. Run the work that follows
  a body read through `wrap_errors/2` so the error reaches Phoenix with the
  conn the read returned.
  """

  @spec wrap_errors(Plug.Conn.t(), (Plug.Conn.t() -> result)) :: result when result: term()
  def wrap_errors(%Plug.Conn{} = conn, fun) when is_function(fun, 1) do
    fun.(conn)
  rescue
    exception in Plug.Conn.WrapperError ->
      reraise(exception, __STACKTRACE__)
  catch
    kind, reason ->
      stack = __STACKTRACE__
      wrapper = %Plug.Conn.WrapperError{conn: conn, kind: kind, reason: reason, stack: stack}
      :erlang.raise(:error, wrapper, stack)
  end
end
