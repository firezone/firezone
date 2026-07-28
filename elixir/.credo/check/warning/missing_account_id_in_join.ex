defmodule Credo.Check.Warning.MissingAccountIdInJoin do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Ecto join conditions should reference `account_id`.

      Portal.Safe scopes only the root query binding. It does not add account
      predicates to joined tables, so tenant-owned rows must be joined with an
      explicit account condition.

      Joins to Portal.Account and `assoc(..., :account)` are exempt because the
      accounts table is not tenant-owned. Intentional joins that do not need an
      account condition should use a targeted Credo disable comment.
      """,
      params: []
    ]

  @join_options [
    :join,
    :inner_join,
    :cross_join,
    :cross_lateral_join,
    :left_join,
    :right_join,
    :full_join,
    :inner_lateral_join,
    :left_lateral_join
  ]

  @doc false
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta), [])
    |> Enum.reverse()
  end

  defp traverse({:from, _meta, args} = ast, issues, issue_meta) when is_list(args) do
    {ast, issues_for_from(args, issues, issue_meta)}
  end

  defp traverse({:join, meta, args} = ast, issues, issue_meta) when is_list(args) do
    {ast, issues_for_join_call(args, meta[:line], issues, issue_meta)}
  end

  defp traverse(
         {{:., _dot_meta, [_module, function]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when function in [:from, :join] and is_list(args) do
    issues =
      case function do
        :from -> issues_for_from(args, issues, issue_meta)
        :join -> issues_for_join_call(args, meta[:line], issues, issue_meta)
      end

    {ast, issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp issues_for_from(args, issues, issue_meta) do
    case Enum.find(Enum.reverse(args), &keyword_list?/1) do
      nil ->
        issues

      options ->
        options
        |> Enum.with_index()
        |> Enum.reduce(issues, fn
          {{join_type, source}, index}, issues when join_type in @join_options ->
            on =
              options
              |> Enum.drop(index + 1)
              |> Enum.take_while(fn {option, _value} -> option not in @join_options end)
              |> Keyword.get(:on)

            maybe_add_issue(
              join_type,
              source,
              on,
              ast_line(source),
              issues,
              issue_meta
            )

          _option, issues ->
            issues
        end)
    end
  end

  defp issues_for_join_call(args, line_no, issues, issue_meta) do
    case Enum.split_while(args, &(not join_source?(&1))) do
      {_before_source, [source | after_source]} ->
        options = Enum.find(after_source, &keyword_list?/1) || []
        on = Keyword.get(options, :on)
        maybe_add_issue(:join, source, on, line_no || ast_line(source), issues, issue_meta)

      {_before_source, []} ->
        issues
    end
  end

  defp maybe_add_issue(join_type, source, on, line_no, issues, issue_meta) do
    if account_source?(source) or contains_account_id?(on) do
      issues
    else
      [issue_for(join_type, line_no, issue_meta) | issues]
    end
  end

  defp join_source?({:in, _meta, [_binding, _source]}), do: true
  defp join_source?(_ast), do: false

  defp account_source?({:in, _meta, [_binding, source]}), do: account_source?(source)
  defp account_source?({:assoc, _meta, [_parent, :account]}), do: true
  defp account_source?({:__aliases__, _meta, parts}), do: List.last(parts) == :Account
  defp account_source?("accounts"), do: true
  defp account_source?(_ast), do: false

  defp contains_account_id?(nil), do: false

  defp contains_account_id?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        :account_id = node, false -> {node, true}
        {:account_id, _meta, _context} = node, false -> {node, true}
        node, false -> {node, false}
      end)

    found?
  end

  defp keyword_list?(value), do: is_list(value) and Keyword.keyword?(value)

  defp ast_line({_name, meta, _args}) when is_list(meta), do: meta[:line]
  defp ast_line(_ast), do: nil

  defp issue_for(join_type, line_no, issue_meta) do
    trigger = to_string(join_type)

    format_issue(
      issue_meta,
      message:
        "Join condition does not reference account_id. " <>
          "Portal.Safe scopes only the root query binding; add an account_id condition to this join.",
      trigger: trigger,
      line_no: line_no
    )
  end
end
