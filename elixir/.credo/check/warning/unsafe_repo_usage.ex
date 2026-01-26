defmodule Credo.Check.Warning.UnsafeRepoUsage do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Portal.Repo should only be called in specific allowed contexts.

      Allowed contexts:
      - Portal.Safe module
      - Database modules (inline modules named "Database")
      - seeds.exs files
      - Test fixtures
      - Mix tasks
      - Database migrations

      Database modules should use Repo with the :subject option:
        Repo.all(query, subject: subject)
        Repo.insert_with_subject(changeset, subject)
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
        Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta, []), {[], []})
        |> elem(0)
    end
  end

  # Track when we enter/exit module definitions
  defp traverse(
         {:defmodule, _meta, [{:__aliases__, _, module_parts}, _]} = ast,
         {issues, module_stack},
         _issue_meta,
         _parent
       ) do
    module_name = Enum.map_join(module_parts, ".", &to_string/1)
    new_stack = module_stack ++ [module_name]
    {ast, {issues, new_stack}}
  end

  # Check for alias Portal.Repo
  defp traverse(
         {:alias, meta, [{:__aliases__, _, [:Portal, :Repo]}]} = ast,
         {issues, module_stack},
         issue_meta,
         _parent
       ) do
    if in_database_module?(module_stack) do
      # Allow in Database modules
      {ast, {issues, module_stack}}
    else
      {ast, {[issue_for(meta[:line], issue_meta, module_stack) | issues], module_stack}}
    end
  end

  # Check for alias Portal.Repo, as: Something
  defp traverse(
         {:alias, meta, [{:__aliases__, _, [:Portal, :Repo]}, _]} = ast,
         {issues, module_stack},
         issue_meta,
         _parent
       ) do
    if in_database_module?(module_stack) do
      # Allow in Database modules
      {ast, {issues, module_stack}}
    else
      {ast, {[issue_for(meta[:line], issue_meta, module_stack) | issues], module_stack}}
    end
  end

  # Check for direct Portal.Repo calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Portal, :Repo]}, _]}, _, _} = ast,
         {issues, module_stack},
         issue_meta,
         _parent
       ) do
    if in_database_module?(module_stack) do
      # Allow in Database modules
      {ast, {issues, module_stack}}
    else
      {ast, {[issue_for(meta[:line], issue_meta, module_stack) | issues], module_stack}}
    end
  end

  # Check for Repo calls (when aliased at module level)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Repo]}, _]}, _, _} = ast,
         {issues, module_stack},
         issue_meta,
         _parent
       ) do
    if in_database_module?(module_stack) do
      # Allow in Database modules
      {ast, {issues, module_stack}}
    else
      {ast, {[issue_for(meta[:line], issue_meta, module_stack) | issues], module_stack}}
    end
  end

  defp traverse(ast, acc, _issue_meta, _parent) do
    {ast, acc}
  end

  # Check if we're in a Database module anywhere in the module hierarchy
  defp in_database_module?(module_stack) do
    Enum.any?(module_stack, fn module_name ->
      module_name == "Database" or String.ends_with?(module_name, ".Database")
    end)
  end

  defp issue_for(line_no, issue_meta, module_stack) do
    current_module = List.last(module_stack)
    location = if current_module, do: " (in module #{inspect(current_module)})", else: ""

    format_issue(
      issue_meta,
      message:
        "Portal.Repo should not be called directly here#{location}. Move this call to a Database module, or ensure you're in an allowed context (Portal.Safe module, seeds.exs, test fixtures, mix tasks, or migrations).",
      trigger: "Portal.Repo",
      line_no: line_no
    )
  end
end
