defmodule Lua.Parser.Comments do
  @moduledoc """
  Helper functions for collecting and attaching comments to AST nodes.
  """

  alias Lua.AST.Meta
  alias Lua.Lexer

  @type token :: Lexer.token()
  @type comment :: Meta.comment()

  @doc """
  Collects leading comments from a token stream.

  Returns `{collected_comments, remaining_tokens}`.
  Stops collecting when it encounters a non-comment token.
  """
  @spec collect_leading_comments([token()]) :: {[comment()], [token()]}
  def collect_leading_comments(tokens) do
    collect_leading_comments_acc(tokens, [])
  end

  defp collect_leading_comments_acc([{:comment, type, text, pos} | rest], acc) do
    comment = %{type: type, text: text, position: pos}
    collect_leading_comments_acc(rest, [comment | acc])
  end

  defp collect_leading_comments_acc(tokens, acc) do
    {Enum.reverse(acc), tokens}
  end

  @doc """
  Checks if there's a trailing comment on the same line as the given position.

  Returns `{maybe_comment, remaining_tokens}`.
  Only captures a comment if it's on the same line as the statement.
  """
  @spec check_trailing_comment([token()], Meta.position() | nil) ::
          {comment() | nil, [token()]}
  def check_trailing_comment(tokens, statement_pos) when is_nil(statement_pos) do
    {nil, tokens}
  end

  def check_trailing_comment([{:comment, type, text, pos} | rest], statement_pos) do
    if pos.line == statement_pos.line do
      comment = %{type: type, text: text, position: pos}
      {comment, rest}
    else
      {nil, [{:comment, type, text, pos} | rest]}
    end
  end

  def check_trailing_comment(tokens, _statement_pos) do
    {nil, tokens}
  end

  @doc """
  Attaches collected comments to an AST node's meta.

  Adds leading comments and optionally a trailing comment.
  """
  @spec attach_comments(Meta.t() | nil, [comment()], comment() | nil) :: Meta.t()
  def attach_comments(meta, leading_comments, trailing_comment) do
    meta = meta || Meta.new()

    meta =
      Enum.reduce(leading_comments, meta, fn comment, acc ->
        Meta.add_leading_comment(acc, comment)
      end)

    if trailing_comment do
      Meta.set_trailing_comment(meta, trailing_comment)
    else
      meta
    end
  end

  @doc """
  Skips any whitespace-like tokens (currently just EOF checks).
  Comments are not skipped here as they need to be processed.
  """
  @spec skip_insignificant([token()]) :: [token()]
  def skip_insignificant(tokens), do: tokens
end
