defmodule FzHttpWeb.AcceptanceCase do
  use ExUnit.CaseTemplate
  alias Wallaby.Query
  import Wallaby.Browser

  using do
    quote do
      # Import conveniences for testing with browser
      use Wallaby.DSL
      use FzHttpWeb, :verified_routes
      import FzHttpWeb.AcceptanceCase
      alias FzHttp.Repo
      alias FzHttpWeb.AcceptanceCase.{Vault, SimpleSAML, Auth}

      # The default endpoint for testing
      @endpoint FzHttpWeb.Endpoint
      @moduletag :acceptance
      @moduletag timeout: 120_000

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

    user_agent =
      Wallaby.Metadata.append(
        "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/41.0.2228.0 Safari/537.36",
        metadata
      )

    %{
      timeout: if(tags[:debug] == true, do: :infinity, else: 120_000),
      session: session,
      debug?: tags[:debug] == true,
      sql_sandbox_metadata: metadata,
      user_agent: user_agent
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
      take_screenshot(s, name: filename, log: true).screenshots
    end)
  end

  def assert_el(session, query, started_at \\ nil)

  def assert_el(session, %Query{} = query, started_at) do
    now = :erlang.monotonic_time(:milli_seconds)
    started_at = started_at || now

    try do
      case execute_query(session, query) do
        {:ok, _query_result} ->
          session

        {:error, {:not_found, results}} ->
          query = %Query{query | result: results}

          raise Wallaby.ExpectationNotMetError,
                Query.ErrorMessage.message(query, :not_found)

        {:error, e} ->
          raise Wallaby.QueryError,
                Query.ErrorMessage.message(query, e)
      end

      assert_has(session, query)
    rescue
      e in [
        Wallaby.ExpectationNotMetError,
        Wallaby.StaleReferenceError,
        Wallaby.QueryError
      ] ->
        time_spent = now - started_at
        max_wait_seconds = fetch_max_wait_seconds!()

        if time_spent > :timer.seconds(max_wait_seconds) do
          reraise(e, __STACKTRACE__)
        else
          floor(time_spent / 10)
          |> max(100)
          |> :timer.sleep()

          assert_el(session, query, started_at)
        end
    end
  end

  defp fetch_max_wait_seconds! do
    if env = System.get_env("E2E_MAX_WAIT_SECONDS") do
      String.to_integer(env)
    else
      2
    end
  end

  def wait_for(assertion_callback, started_at \\ nil) do
    now = :erlang.monotonic_time(:milli_seconds)
    started_at = started_at || now

    try do
      assertion_callback.()
    rescue
      e in [ExUnit.AssertionError] ->
        time_spent = now - started_at
        max_wait_seconds = fetch_max_wait_seconds!()

        if time_spent > :timer.seconds(max_wait_seconds) do
          reraise(e, __STACKTRACE__)
        else
          floor(time_spent / 10)
          |> max(100)
          |> :timer.sleep()

          wait_for(assertion_callback, started_at)
        end
    end
  end

  def fill_form(session, %{} = fields) do
    # Wait for form to be rendered
    {form_el, _opts} = Enum.at(fields, 0)
    session = assert_el(session, Query.fillable_field(form_el))

    # Make sure test covers all form fields
    element_names =
      session
      |> find(Query.css(".input,.textarea", visible: true, count: :any))
      |> Enum.map(&Wallaby.Element.attr(&1, "name"))

    unless Enum.count(fields) == length(element_names) do
      flunk(
        "Expected #{Enum.count(fields)} elements, " <>
          "got #{length(element_names)}: #{inspect(element_names)}"
      )
    end

    Enum.reduce(fields, session, fn {field, value}, session ->
      fill_in(session, Query.fillable_field(field), with: value)
    end)
  end

  def toggle(session, selector) do
    selector = ~s|document.querySelector("input[name=\\\"#{selector}\\\"]").click()|

    # For some reason Wallaby can't click on checkboxes,
    # probably because they have absolute positioning
    session = execute_script(session, selector)

    # If we don't sleep animations won't be finished on form submit
    Process.sleep(50)

    session
  end

  def assert_path(session, path) do
    assert current_path(session) == path
    session
  end

  def shutdown_live_socket(session) do
    Wallaby.end_session(session)
    Process.sleep(10)
    # await_for_sandbox_processes()
  end

  # defp await_for_sandbox_processes() do
  #   receive do
  #     {:sandbox_access, pid} ->
  #       await_for_process_death(pid)
  #       await_for_sandbox_processes()

  #     _ ->
  #       await_for_sandbox_processes()
  #   after
  #     10 -> :ok
  #   end
  # end

  # defp await_for_process_death(pid, retries_left \\ 5) do
  #   cond do
  #     not Process.alive?(pid) ->
  #       :ok

  #     retries_left > 0 ->
  #       Process.sleep(10)
  #       await_for_process_death(pid, retries_left - 1)

  #     true ->
  #       Process.exit(pid, :kill)
  #   end
  # end

  @doc """
  This is an extension of ExUnit's `test` macro but:

  - it rescues the exceptions from Wallaby and prints them while sleeping the process
  (to allow you interacting with the browser) if test has `debug: true` tag;

  - it takes a screenshot on failure if `debug` tag is not set to `true` or unset.

  Additionally, it will try to await for all the sandboxed processes to finish their work
  after the test has passed to prevent spamming logs with a lot of crash reports.
  """
  defmacro feature(message, var \\ quote(do: _), contents) do
    contents =
      case contents do
        [do: block] ->
          quote do
            try do
              unquote(block)
              if var!(debug?) == true, do: Process.sleep(360_000)
              shutdown_live_socket(var!(session))
              :ok
            rescue
              e ->
                cond do
                  var!(debug?) == true ->
                    IO.puts(
                      IO.ANSI.red() <>
                        "Warning! This test runs in browser-debug mode, " <>
                        "it will sleep the test process for infinity." <> IO.ANSI.reset()
                    )

                    IO.puts("")
                    IO.puts(IO.ANSI.yellow())
                    IO.puts("Exception was rescued:")
                    IO.puts(Exception.format(:error, e, __STACKTRACE__))
                    IO.puts(IO.ANSI.reset())
                    Process.sleep(:infinity)

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

    quote bind_quoted: [
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
