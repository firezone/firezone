defmodule Credo.Check.Warning.MissingHandleInfoCatchAll do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      LiveView modules that define `handle_info/2` clauses must include a catch-all
      clause as the final clause.

      Without a catch-all, any unexpected message will crash the LiveView process
      with a `FunctionClauseError`. From the user's perspective this causes a silent
      page reload that wipes any in-progress form edits — a confusing and broken
      experience.

      Add a catch-all as the final `handle_info/2` clause:

          def handle_info(message, socket) do
            PortalWeb.Live.Helpers.handle_info_fallback(message, socket)
          end

      ## Examples

      Bad:

          def handle_info(%Change{}, socket) do
            {:noreply, socket}
          end

      Good:

          def handle_info(%Change{}, socket) do
            {:noreply, socket}
          end

          def handle_info(message, socket) do
            PortalWeb.Live.Helpers.handle_info_fallback(message, socket)
          end
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    state = analyze_module(source_file)

    if state.uses_live_view and state.has_handle_info and not state.has_catch_all do
      [issue_for(state.first_handle_info_line, issue_meta)]
    else
      []
    end
  end

  defp analyze_module(source_file) do
    initial_state = %{
      uses_live_view: false,
      has_handle_info: false,
      has_catch_all: false,
      first_handle_info_line: nil
    }

    Credo.Code.prewalk(source_file, &collect_info(&1, &2), initial_state)
  end

  # use PortalWeb, :live_view  or  use SomeModule, :live_view
  # Skip quote blocks — they are macro templates, not real module definitions
  defp collect_info({:quote, _, _}, state) do
    {:skipped, state}
  end

  defp collect_info({:use, _, [{:__aliases__, _, _}, :live_view]} = ast, state) do
    {ast, %{state | uses_live_view: true}}
  end

  # use Phoenix.LiveView (with or without options)
  defp collect_info(
         {:use, _, [{:__aliases__, _, [:Phoenix, :LiveView]} | _]} = ast,
         state
       ) do
    {ast, %{state | uses_live_view: true}}
  end

  # def handle_info(arg1, arg2), ...
  defp collect_info(
         {:def, meta, [{:handle_info, _, [arg1, arg2]}, _body]} = ast,
         state
       ) do
    first_line = state.first_handle_info_line || meta[:line]

    state =
      state
      |> Map.put(:has_handle_info, true)
      |> Map.put(:first_handle_info_line, first_line)

    state =
      if is_variable?(arg1) and is_variable?(arg2) do
        %{state | has_catch_all: true}
      else
        state
      end

    {ast, state}
  end

  defp collect_info(ast, state), do: {ast, state}

  # Plain variable: {:varname, meta, nil}  (nil context = not a remote call or alias)
  defp is_variable?({name, _meta, nil}) when is_atom(name), do: true
  defp is_variable?(_), do: false

  defp issue_for(line_no, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "LiveView defines handle_info/2 clauses but is missing a catch-all. " <>
          "Add `def handle_info(message, socket), do: PortalWeb.Live.Helpers.handle_info_fallback(message, socket)` as the final clause.",
      trigger: "handle_info",
      line_no: line_no
    )
  end
end
