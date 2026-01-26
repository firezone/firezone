defmodule Credo.Check.Warning.SafeUnscopedUsage do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Safe.scoped(subject) should be used instead of Safe.unscoped().

      Using scoped operations ensures proper authorization tracking and follows
      the principle of least privilege. Unscoped operations bypass authorization
      checks and should only be used in exceptional cases.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    # Skip checking the Portal.Safe module itself
    if String.ends_with?(source_file.filename, "domain/lib/domain/safe.ex") do
      []
    else
      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta), [])
    end
  end

  # Check for Portal.Safe.unscoped() calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Portal, :Safe]}, :unscoped]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    issue = issue_for(meta[:line], issue_meta)
    {ast, [issue | issues]}
  end

  # Check for Safe.unscoped() calls (when aliased)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Safe]}, :unscoped]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    issue = issue_for(meta[:line], issue_meta)
    {ast, [issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(line_no, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "Safe.scoped(subject) should be used instead of Safe.unscoped(). Use scoped operations for proper authorization tracking.",
      trigger: "Safe.unscoped",
      line_no: line_no
    )
  end
end
