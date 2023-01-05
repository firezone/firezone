defmodule FzHttpWeb.AcceptanceCase do
  use ExUnit.CaseTemplate

  using do
    quote location: :keep do
      # Import conveniences for testing with browser
      use Wallaby.DSL
      use FzHttpWeb, :verified_routes
      import FzHttpWeb.AcceptanceCase

      # The default endpoint for testing
      @endpoint FzHttpWeb.Endpoint
      @moduletag :acceptance

      setup tags do
        Application.put_env(:wallaby, :base_url, @endpoint.url)
        tags
      end
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(FzHttp.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(FzHttp.Repo, {:shared, self()})
    end

    headless? =
      if tags[:debug] do
        false
      else
        true
      end

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(FzHttp.Repo, self())
    {:ok, session} = start_session(headless?, metadata)

    %{
      session: session,
      debug?: tags[:debug] == true,
      sql_sandbox_metadata: metadata
    }
  end

  defp start_session(headless?, metadata) do
    capabilities =
      [
        metadata: metadata,
        window_size: [width: 1280, height: 720]
      ]
      |> Wallaby.Chrome.default_capabilities()
      |> update_in(
        [:chromeOptions, :args],
        fn args ->
          args = args ++ ["--ignore-ssl-errors", "yes", "--ignore-certificate-errors"]

          if headless? do
            # defaults args already have --headless arg
            args
          else
            args -- ["--headless"]
          end
        end
      )

    Wallaby.start_session(capabilities: capabilities)
  end

  def take_screenshot(name) do
    time = :erlang.system_time(:second) |> to_string()
    name = String.replace(name, " ", "_")

    Wallaby.SessionStore.list_sessions_for(owner_pid: self())
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {s, i} ->
      filename = time <> "_" <> name <> "(#{i})"
      Wallaby.Browser.take_screenshot(s, name: filename, log: true).screenshots
    end)
  end

  @doc """
  This is an extension of ExUnit's `test` macro but:

  - it rescues the exceptions from Wallaby and prints them while sleeping the process
  (to allow you interacting with the browser) if test has `debug: true` tag;

  - it takes a screenshot on failure if `debug` tag is not set to `true` or unset.
  """
  defmacro feature(message, var \\ quote(do: _), contents) do
    contents =
      case contents do
        [do: block] ->
          quote do
            try do
              unquote(block)
              :ok
            rescue
              e ->
                cond do
                  var!(debug?) == true ->
                    IO.puts(
                      IO.ANSI.red() <>
                        "Warning! This test runs in browser-debug mode, " <>
                        "it sleep the test process on failure for 50 seconds." <> IO.ANSI.reset()
                    )

                    IO.puts("")
                    IO.puts(IO.ANSI.yellow())
                    IO.puts("Exception was rescued:")
                    IO.puts(Exception.format(:error, e, __STACKTRACE__))
                    IO.puts(IO.ANSI.reset())
                    Process.sleep(:timer.seconds(50))

                  Wallaby.screenshot_on_failure?() ->
                    unquote(__MODULE__).take_screenshot(unquote(message))

                  true ->
                    :ok
                end

                reraise(e, __STACKTRACE__)
            end
          end
      end

    # Always insert debug? tag from module attributes,
    # which is used by rescue block above
    {op, meta, bindings} = var
    debug_var_binding = {:debug?, {:debug?, meta, nil}}
    var = {op, meta, bindings ++ [debug_var_binding]}
    var = Macro.escape(var)

    contents = Macro.escape(contents, unquote: true)
    %{module: mod, file: file, line: line} = __CALLER__

    quote location: :keep,
          bind_quoted: [
            var: var,
            contents: contents,
            message: message,
            mod: mod,
            file: file,
            line: line
          ] do
      name = ExUnit.Case.register_test(mod, file, line, :test, message, [])
      def unquote(name)(unquote(var)), do: unquote(contents)
    end
  end
end
