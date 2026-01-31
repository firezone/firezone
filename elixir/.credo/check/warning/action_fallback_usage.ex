defmodule Credo.Check.Warning.ActionFallbackUsage do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      The `action_fallback` macro should not be used in controllers.

      Using `action_fallback` breaks stack traces and makes error handling
      harder to follow. Instead, use explicit error handling with a
      centralized Error module:


        with {:ok, resource} <- Database.fetch_resource(id, subject) do
          render(conn, :show, resource: resource)
        else
          error -> Error.handle(conn, error)
        end

      See PortalAPI.Error and PortalWeb.Error for the available error handlers.
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
  end

  # Check for action_fallback macro calls
  defp traverse(
         {:action_fallback, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(meta[:line], issue_meta) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(line_no, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "action_fallback should not be used. Use explicit error handling with Error.handle/2 instead.",
      trigger: "action_fallback",
      line_no: line_no
    )
  end
end
