defmodule Credo.Check.Warning.RepoMissingSubject do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      All Portal.Repo and Portal.Repo.Replica calls must be wrapped in
      Authorization.with_subject/2 to ensure proper authorization.

      Allowed:
        Authorization.with_subject(subject, fn ->
          Repo.insert(changeset)
          Repo.all(query)
        end)

      Not allowed:
        Repo.all(query)   # not inside with_subject
        Repo.insert(cs)   # not inside with_subject

      To bypass this check (e.g., system/worker operations), add:
        # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject
        Repo.all(query)
      """,
      params: []
    ]

  @repo_functions [
    :all,
    :one,
    :one!,
    :get,
    :get!,
    :get_by,
    :get_by!,
    :insert,
    :insert!,
    :update,
    :update!,
    :delete,
    :delete!,
    :insert_all,
    :update_all,
    :delete_all,
    :exists?,
    :aggregate,
    :stream,
    :fetch,
    :fetch!,
    :fetch_unscoped,
    :fetch_unscoped!,
    :exists_scoped?,
    :list,
    :preload,
    :transaction
  ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    file_path = source_file.filename

    if skip_file?(file_path) do
      []
    else
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp skip_file?(path) do
    String.contains?(path, "lib/portal/repo") or
      String.ends_with?(path, "lib/portal/authorization.ex") or
      String.ends_with?(path, "seeds.exs") or
      String.contains?(path, "/test/") or
      String.contains?(path, "/mix/tasks/") or
      String.contains?(path, "/migrations/")
  end

  # Recognize Authorization.with_subject(subject, fn -> ... end) blocks.
  # Returning nil prevents prewalk from descending into the lambda body,
  # so Repo calls inside with_subject are not flagged.
  defp traverse(
         {{:., _, [{:__aliases__, _, aliases}, :with_subject]}, _, _args} = _ast,
         issues,
         _issue_meta
       )
       when aliases in [[:Authorization], [:Portal, :Authorization]] do
    {nil, issues}
  end

  # Repo.function_name(...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Repo]}, function_name]}, _, _args} = ast,
         issues,
         issue_meta
       )
       when function_name in @repo_functions do
    {ast, [issue_for(meta[:line], issue_meta, function_name) | issues]}
  end

  # Portal.Repo.function_name(...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Portal, :Repo]}, function_name]}, _, _args} = ast,
         issues,
         issue_meta
       )
       when function_name in @repo_functions do
    {ast, [issue_for(meta[:line], issue_meta, function_name) | issues]}
  end

  # Portal.Repo.Replica.function_name(...)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Portal, :Repo, :Replica]}, function_name]}, _, _args} =
           ast,
         issues,
         issue_meta
       )
       when function_name in @repo_functions do
    {ast, [issue_for(meta[:line], issue_meta, function_name) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(line_no, issue_meta, function_name) do
    format_issue(
      issue_meta,
      message:
        "Repo.#{function_name} call must be wrapped in Authorization.with_subject/2. " <>
          "To bypass: # credo:disable-for-next-line Credo.Check.Warning.RepoMissingSubject",
      trigger: "Repo.#{function_name}",
      line_no: line_no
    )
  end
end
