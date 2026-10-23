defmodule PortalAPI.Device.Channel.Durability do
  @moduledoc """
  Fail-closed timers for what a channel announced before the database had it.

  A session and every authorization a device is told about are written
  through `Portal.Queue`, which confirms each flush. Until it does, a timer
  runs here; if it fires, the originating queue lost state (crash, OOM, a
  node that died) and the channel acts as if the write had failed.

  Each armed authorization timer carries a `make_ref/0` generation token, and
  `authz_durability` stores `%{authz_id => {generation, timer_ref}}`. A
  firing timer is only acted on when its generation is still the current
  one: `Process.cancel_timer/1` cannot remove a message already delivered
  to the mailbox, so a timer that fires just before its confirmation arrives
  must be told apart from a live one.
  """

  import Phoenix.Socket, only: [assign: 3]

  require Logger

  @authz_timeout :timer.seconds(15)
  @session_timeout :timer.seconds(15)

  @doc "Arms the timer for the session row this channel enqueued."
  @spec arm_session(Phoenix.Socket.t()) :: Phoenix.Socket.t()
  def arm_session(socket) do
    session_ref = socket.assigns.session_ref

    timer_ref =
      Process.send_after(self(), {:session_durability_timeout, session_ref}, @session_timeout)

    assign(socket, :session_durability, {session_ref, timer_ref})
  end

  @doc "The session row was flushed; its timer is stopped."
  @spec confirm_session(Phoenix.Socket.t(), reference()) :: Phoenix.Socket.t()
  def confirm_session(socket, session_ref) do
    case socket.assigns[:session_durability] do
      {^session_ref, timer_ref} ->
        Process.cancel_timer(timer_ref)
        assign(socket, :session_durability, nil)

      _ ->
        socket
    end
  end

  @doc "Whether a session timeout for `session_ref` is the live one, so the channel should stop."
  @spec session_expired?(Phoenix.Socket.t(), reference()) :: boolean()
  def session_expired?(socket, session_ref) do
    match?({^session_ref, _timer_ref}, socket.assigns[:session_durability])
  end

  @doc "Arms a timer for an authorization the device was just told about. `nil` arms nothing."
  @spec arm_authorization(Phoenix.Socket.t(), Portal.PolicyAuthorization.t() | nil) ::
          Phoenix.Socket.t()
  def arm_authorization(socket, nil), do: socket

  def arm_authorization(socket, %Portal.PolicyAuthorization{} = pa) do
    generation = make_ref()

    timer_ref =
      Process.send_after(self(), {:authz_durability_timeout, pa, generation}, @authz_timeout)

    pending = socket.assigns[:authz_durability] || %{}

    # A timer already armed for this id should not happen, but if it did, its
    # message may still arrive; the generation check ignores it.
    case Map.get(pending, pa.id) do
      nil -> :ok
      {_old_generation, old_ref} -> Process.cancel_timer(old_ref)
    end

    assign(socket, :authz_durability, Map.put(pending, pa.id, {generation, timer_ref}))
  end

  @doc "The authorization was flushed or rejected; its timer is stopped."
  @spec confirm_authorization(Phoenix.Socket.t(), Ecto.UUID.t()) :: Phoenix.Socket.t()
  def confirm_authorization(socket, authz_id) do
    pending = socket.assigns[:authz_durability] || %{}

    case Map.pop(pending, authz_id) do
      {nil, _} ->
        socket

      {{_generation, timer_ref}, rest} ->
        Process.cancel_timer(timer_ref)
        assign(socket, :authz_durability, rest)
    end
  end

  @doc """
  Whether a fired authorization timer is still the live one for its id. When
  it is, the entry is dropped and the caller revokes the authorization.
  """
  @spec authorization_timed_out(Phoenix.Socket.t(), Portal.PolicyAuthorization.t(), reference()) ::
          {:timed_out, Phoenix.Socket.t()} | :stale
  def authorization_timed_out(socket, %Portal.PolicyAuthorization{} = pa, generation) do
    case Map.get(socket.assigns[:authz_durability] || %{}, pa.id) do
      {^generation, _ref} ->
        Logger.warning(
          "Authz durability timeout firing for authz #{inspect(pa.id)} — queue never confirmed durability"
        )

        {:timed_out, confirm_authorization(socket, pa.id)}

      _ ->
        :stale
    end
  end
end
