defmodule PortalAPI.Channel.Durability do
  @moduledoc """
  Timers that fail closed when a write a channel relies on never reaches the database.

  A channel acts on a session or an authorization before the queue that persists it has
  flushed. The queue confirms the flush, or rejects it on failure. If neither arrives in time,
  the queue lost its state (crash, OOM, node death) and the timer fires: the channel then
  disconnects for a session, or revokes for an authorization.

  Each authorization timer carries a generation ref. `Process.cancel_timer/1` cannot remove a
  message already in the mailbox, so a timeout whose generation no longer matches (cancelled or
  replaced) is ignored.
  """
  import Phoenix.Socket, only: [assign: 3]

  @timeout :timer.seconds(15)

  @spec arm_session(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def arm_session(socket) do
    session_ref = socket.assigns.session_ref
    timer_ref = Process.send_after(self(), {:session_durability_timeout, session_ref}, @timeout)
    assign(socket, :session_durability, {session_ref, timer_ref})
  end

  @spec cancel_session(Phoenix.Socket.t(), reference()) :: Phoenix.Socket.t()
  def cancel_session(socket, session_ref) do
    case socket.assigns[:session_durability] do
      {^session_ref, timer_ref} ->
        Process.cancel_timer(timer_ref)
        assign(socket, :session_durability, nil)

      _ ->
        socket
    end
  end

  @doc "Whether a session timeout is for the session still waiting on its flush."
  @spec session_lost?(Phoenix.Socket.t(), reference()) :: boolean()
  def session_lost?(socket, session_ref) do
    match?({^session_ref, _timer_ref}, socket.assigns[:session_durability])
  end

  @spec arm_authorization(Phoenix.Socket.t(), Portal.PolicyAuthorization.t() | nil) ::
          Phoenix.Socket.t()
  def arm_authorization(socket, nil), do: socket

  def arm_authorization(socket, %Portal.PolicyAuthorization{} = pa) do
    generation = make_ref()
    timer_ref = Process.send_after(self(), {:authz_durability_timeout, pa, generation}, @timeout)
    pending = socket.assigns[:authz_durability] || %{}

    case Map.get(pending, pa.id) do
      nil -> :ok
      {_old_generation, old_ref} -> Process.cancel_timer(old_ref)
    end

    assign(socket, :authz_durability, Map.put(pending, pa.id, {generation, timer_ref}))
  end

  @spec cancel_authorization(Phoenix.Socket.t(), Ecto.UUID.t()) :: Phoenix.Socket.t()
  def cancel_authorization(socket, authz_id) do
    pending = socket.assigns[:authz_durability] || %{}

    case Map.pop(pending, authz_id) do
      {nil, _} ->
        socket

      {{_generation, timer_ref}, rest} ->
        Process.cancel_timer(timer_ref)
        assign(socket, :authz_durability, rest)
    end
  end

  @doc "Whether an authorization timeout is for the timer still armed for it."
  @spec authorization_lost?(Phoenix.Socket.t(), Portal.PolicyAuthorization.t(), reference()) ::
          boolean()
  def authorization_lost?(socket, %Portal.PolicyAuthorization{} = pa, generation) do
    match?({^generation, _ref}, Map.get(socket.assigns[:authz_durability] || %{}, pa.id))
  end
end
