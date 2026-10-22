defmodule Credo.Check.Warning.AsyncFalseInTest do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    run_on_all: true,
    explanations: [
      check: """
      Test modules must not opt out of asynchronous execution with `async: false`.

      Run the test module asynchronously and isolate mutable state with unique
      process names, process-scoped configuration, and per-test resources.
      """,
      params: []
    ]

  @impl true
  def run_on_all_source_files(exec, _source_files, params) do
    exec
    |> Execution.working_dir()
    |> Credo.Sources.find_in_dir(["test/**/*.{ex,exs}"], [])
    |> Enum.each(fn filename ->
      source_file = filename |> File.read!() |> SourceFile.parse(filename)
      run_on_source_file(exec, source_file, params)
    end)
  end

  @doc false
  def run(source_file, params \\ []) do
    if test_file?(source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
    else
      []
    end
  end

  defp traverse({:use, meta, [_case_module, options]} = ast, issues, issue_meta)
       when is_list(options) do
    if Keyword.get(options, :async) == false do
      issue =
        format_issue(
          issue_meta,
          message:
            "Test modules must run asynchronously. Replace `async: false` with `async: true` and isolate shared state.",
          trigger: "async: false",
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp test_file?(filename) do
    filename
    |> String.replace("\\", "/")
    |> String.match?(~r{(^|/)test/.*\.(ex|exs)$})
  end
end
