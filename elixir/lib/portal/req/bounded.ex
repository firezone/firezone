defmodule Portal.Req.Bounded do
  @moduledoc """
  Makes an HTTP request whose cost stays bounded however the server answers.

  Use it for requests to addresses that a customer or a remote document
  supplies. Accepts every `Req` option, plus:

    * `:max_body_bytes` - required. The body is read as a stream and the read
      stops as soon as it passes this many bytes.
    * `:timeout` - the time in milliseconds the whole call may take, retries,
      redirects and their delays included. Defaults to 30 seconds.

  `:receive_timeout` defaults to 15 seconds and never exceeds `:timeout`.
  `:max_redirects` defaults to 3. `:into` is owned by this module.

  The body is never decompressed, so `:max_body_bytes` is also the memory the
  body can take. It is still decoded (JSON, for example) as `Req` would do.

  Returns `{:ok, response}` with a binary body, or `{:error, exception}`. A body
  that is too large gives `Portal.Req.Bounded.BodyTooLargeError`, and a call
  that runs out of time gives `Req.TransportError` with reason `:timeout`.
  """

  @default_timeout :timer.seconds(30)
  @default_receive_timeout :timer.seconds(15)
  @default_max_redirects 3

  defmodule BodyTooLargeError do
    defexception [:max_bytes]

    @impl true
    def message(%__MODULE__{max_bytes: max_bytes}) do
      "response body is larger than #{max_bytes} bytes"
    end
  end

  @spec request(keyword()) :: {:ok, Req.Response.t()} | {:error, Exception.t()}
  def request(options) do
    {max_bytes, options} = Keyword.pop!(options, :max_body_bytes)
    {timeout, options} = Keyword.pop(options, :timeout, @default_timeout)

    options =
      options
      |> Keyword.put_new(:max_redirects, @default_max_redirects)
      |> Keyword.update(
        :receive_timeout,
        min(@default_receive_timeout, timeout),
        &min(&1, timeout)
      )
      |> Keyword.put(:into, &collect(&1, &2, max_bytes))

    metadata = Logger.metadata()

    task =
      Task.async(fn ->
        Logger.metadata(metadata)
        run(options, max_bytes)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _other -> {:error, %Req.TransportError{reason: :timeout}}
    end
  end

  defp run(options, max_bytes) do
    options
    |> Req.new()
    |> Req.Request.prepend_response_steps(bounded_body: &finish(&1, max_bytes))
    |> Req.request()
  rescue
    exception -> {:error, exception}
  end

  defp collect({:data, data}, {request, response}, max_bytes) do
    size = Req.Response.get_private(response, :bounded_body_bytes, 0) + byte_size(data)

    if size > max_bytes do
      response = %{response | body: ""} |> Req.Response.put_private(:bounded_body_bytes, size)
      {:halt, {request, response}}
    else
      response =
        %{response | body: [response.body, data]}
        |> Req.Response.put_private(:bounded_body_bytes, size)

      {:cont, {request, response}}
    end
  end

  defp finish({request, response}, max_bytes) do
    cond do
      Req.Response.get_private(response, :bounded_body_bytes, 0) > max_bytes ->
        {request, %BodyTooLargeError{max_bytes: max_bytes}}

      is_list(response.body) ->
        {request, %{response | body: IO.iodata_to_binary(response.body)}}

      true ->
        {request, response}
    end
  end
end
