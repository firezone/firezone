defmodule Credo.Check.Warning.UnsafeRepoUsage do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Portal.Repo should only be called in specific allowed contexts.
      Use Portal.Safe in all other application contexts.

      Allowed contexts:
      - Portal.Safe module
      - seeds.exs files
      - Test fixtures
      - Mix tasks
      - Database migrations
      """,
      params: []
    ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    file_path = source_file.filename

    cond do
      # Allow in Portal.Safe module
      String.ends_with?(file_path, "lib/portal/safe.ex") ->
        []

      # Allow in Portal.Repo itself and its submodules (Preloader, Paginator, Filter, Query)
      String.contains?(file_path, "lib/portal/repo") ->
        []

      # Allow in seeds.exs files
      String.ends_with?(file_path, "seeds.exs") ->
        []

      # Allow in test fixtures
      String.contains?(file_path, "test/") and String.contains?(file_path, "fixtures") ->
        []

      # Allow in mix tasks
      String.contains?(file_path, "/mix/tasks/") ->
        []

      # Allow in migrations
      String.contains?(file_path, "/migrations/") ->
        []

      # Check for violations in all other files
      true ->
        Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), [])
    end
  end

  # Check for alias Portal.Repo
  defp traverse(
         {:alias, meta, [{:__aliases__, _, [:Portal, :Repo]}]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(ast, meta[:line], issue_meta) | issues]}
  end

  # Check for alias Portal.Repo, as: Something
  defp traverse(
         {:alias, meta, [{:__aliases__, _, [:Portal, :Repo]}, _]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(ast, meta[:line], issue_meta) | issues]}
  end

  # Allow Portal.Repo.valid_uuid? - it's a utility function, not a database operation
  defp traverse(
         {{:., _meta, [{:__aliases__, _, [:Portal, :Repo]}, :valid_uuid?]}, _, _} = ast,
         issues,
         _issue_meta
       ) do
    {ast, issues}
  end

  # Allow Repo.valid_uuid? (when aliased)
  defp traverse(
         {{:., _meta, [{:__aliases__, _, [:Repo]}, :valid_uuid?]}, _, _} = ast,
         issues,
         _issue_meta
       ) do
    {ast, issues}
  end

  # Check for direct Portal.Repo calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Portal, :Repo]}, _]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(ast, meta[:line], issue_meta) | issues]}
  end

  # Check for Repo calls (when aliased at module level)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Repo]}, _]}, _, _} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(ast, meta[:line], issue_meta) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(_ast, line_no, issue_meta) do
    format_issue(
      issue_meta,
      message:
        "Portal.Repo should not be called directly here. Use Portal.Safe instead or ensure you're in an allowed context (Portal.Safe module, seeds.exs, test fixtures, mix tasks, or migrations).",
      trigger: "Portal.Repo",
      line_no: line_no
    )
  end
end
