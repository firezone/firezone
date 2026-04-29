defmodule Credo.Check.Warning.UnsafeTemplateHTML do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    run_on_all: true,
    param_defaults: [
      template_globs: ["lib/**/*.html.eex", "lib/**/*.heex"]
    ],
    explanations: [
      check: """
      HTML templates should rely on Phoenix template escaping for dynamic content.

      Do not use explicit HTML-safe markers in HTML templates. These bypass
      or obscure escaping guarantees and make template review more error-prone.

      Disable this check only for audited static markup using an EEx comment:

          <%# credo:disable-for-next-line Credo.Check.Warning.UnsafeTemplateHTML %>
      """,
      params: [
        template_globs: "HTML template globs to scan."
      ]
    ]

  @check_name inspect(__MODULE__)
  @short_check_name __MODULE__ |> Module.split() |> List.last()

  @unsafe_patterns [
    %{
      regex: ~r/(<%==)/,
      capture: 1,
      trigger: "<%==",
      message:
        "HTML templates must not use unescaped EEx output. Use `<%= ... %>` and let Phoenix escape dynamic values."
    },
    %{
      regex: ~r/(Phoenix\.HTML\.raw)\s*\(/,
      capture: 1,
      trigger: "Phoenix.HTML.raw",
      message:
        "HTML templates must not mark content as raw HTML. Render values directly and let Phoenix escape them."
    },
    %{
      regex: ~r/(^|[^\w.])(raw)\s*\(/,
      capture: 2,
      trigger: "raw",
      message:
        "HTML templates must not mark content as raw HTML. Render values directly and let Phoenix escape them."
    },
    %{
      regex: ~r/(\{\s*:safe\s*,)/,
      capture: 1,
      trigger: "{:safe,",
      message:
        "HTML templates must not mark content as HTML-safe. Render values directly and let Phoenix escape them."
    },
    %{
      regex: ~r/(Phoenix\.HTML\.Safe)\b/,
      capture: 1,
      trigger: "Phoenix.HTML.Safe",
      message:
        "HTML templates must not use the Phoenix.HTML.Safe protocol directly. Render values directly and let Phoenix escape them."
    },
    %{
      regex: ~r/(^|[^\w.])((?:Phoenix\.HTML\.)?safe_to_string)\s*\(/,
      capture: 2,
      trigger: "safe_to_string",
      message:
        "HTML templates must not convert safe HTML to strings. Render values directly and let Phoenix escape them."
    }
  ]

  @eex_tag_regex ~r/<%(?![#\!]).*?%>/s
  @heex_expression_regex ~r/\{[^\n{}]*\}/
  @disable_comment_regex ~r/<%(?:#|!--)\s*credo:([\w:-]+)\s*(.*?)\s*(?:--)?%>/

  @doc false
  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    issues =
      case List.first(source_files) do
        nil -> []
        source_file -> template_issues(source_file, params)
      end

    append_issues_and_timings(issues, exec)

    :ok
  end

  @doc false
  def template_issues(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    params
    |> Keyword.get(:template_globs, param_defaults()[:template_globs])
    |> template_paths()
    |> Enum.flat_map(&issues_for_template(&1, issue_meta))
  end

  defp template_paths(globs) do
    globs
    |> List.wrap()
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp issues_for_template(path, issue_meta) do
    source = File.read!(path)
    disable_comments = disable_comments(source)

    if disables_file?(disable_comments) do
      []
    else
      source
      |> template_expressions(path)
      |> Enum.flat_map(&unsafe_matches(source, &1))
      |> Enum.reject(&disabled_line?(disable_comments, &1.line_no))
      |> Enum.map(&issue_for(&1, path, issue_meta))
    end
  end

  defp template_expressions(source, path) do
    if String.ends_with?(path, ".heex") do
      eex_tags(source) ++ heex_expressions(source)
    else
      eex_tags(source)
    end
  end

  defp eex_tags(source) do
    @eex_tag_regex
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, length}] ->
      {start, binary_part(source, start, length)}
    end)
  end

  defp heex_expressions(source) do
    @heex_expression_regex
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, length}] ->
      {start, binary_part(source, start, length)}
    end)
  end

  defp unsafe_matches(source, {tag_start, tag}) do
    Enum.flat_map(@unsafe_patterns, fn pattern ->
      pattern.regex
      |> Regex.scan(tag, return: :index, capture: :all)
      |> Enum.map(fn captures ->
        {match_start, match_length} = Enum.at(captures, pattern.capture)
        offset = tag_start + match_start
        {line_no, column} = line_column(source, offset)

        %{
          line_no: line_no,
          column: column,
          trigger: binary_part(tag, match_start, match_length),
          message: pattern.message
        }
      end)
    end)
  end

  defp issue_for(match, path, issue_meta) do
    issue_meta
    |> format_issue(
      message: match.message,
      trigger: match.trigger,
      column: match.column
    )
    |> Map.merge(%{
      filename: Path.relative_to_cwd(path),
      line_no: match.line_no,
      column: match.column,
      scope: nil
    })
  end

  defp line_column(source, offset) do
    before = binary_part(source, 0, offset)
    line_no = length(:binary.matches(before, "\n")) + 1

    column =
      case List.last(:binary.matches(before, "\n")) do
        nil -> byte_size(before) + 1
        {newline_offset, 1} -> byte_size(before) - newline_offset
      end

    {line_no, column}
  end

  defp disable_comments(source) do
    source
    |> String.split("\n", trim: false)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      @disable_comment_regex
      |> Regex.scan(line)
      |> Enum.flat_map(fn [_match, instruction, params] ->
        if applies_to_check?(params) do
          [%{instruction: instruction, line_no: line_no}]
        else
          []
        end
      end)
    end)
  end

  defp applies_to_check?(params) do
    params =
      params
      |> String.trim()
      |> String.split(~r/[\s,]+/, trim: true)

    params == [] or @check_name in params or @short_check_name in params
  end

  defp disables_file?(comments) do
    Enum.any?(comments, &(&1.instruction == "disable-for-this-file"))
  end

  defp disabled_line?(comments, line_no) do
    Enum.any?(comments, &comment_disables_line?(&1, line_no))
  end

  defp comment_disables_line?(%{instruction: "disable-for-next-line", line_no: comment_line}, line_no) do
    line_no == comment_line + 1
  end

  defp comment_disables_line?(%{instruction: "disable-for-previous-line", line_no: comment_line}, line_no) do
    line_no == comment_line - 1
  end

  defp comment_disables_line?(%{instruction: "disable-for-lines:" <> count, line_no: comment_line}, line_no) do
    with {count, ""} <- Integer.parse(count) do
      first_line = min(comment_line, comment_line + count)
      last_line = max(comment_line, comment_line + count)

      line_no >= first_line and line_no <= last_line
    else
      _ -> false
    end
  end

  defp comment_disables_line?(_comment, _line_no), do: false
end
