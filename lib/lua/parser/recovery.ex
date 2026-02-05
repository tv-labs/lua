defmodule Lua.Parser.Recovery do
  @moduledoc """
  Error recovery strategies for the Lua parser.

  Allows the parser to continue after encountering errors,
  collecting multiple errors in a single parse pass.
  """

  alias Lua.Parser.Error
  alias Lua.Lexer

  @type token :: Lexer.token()
  @type recovery_result :: {:recovered, [token()], [Error.t()]} | {:failed, [Error.t()]}

  @doc """
  Attempts to recover from a parse error by finding a synchronization point.

  Synchronization points are tokens where we can safely resume parsing:
  - Statement boundaries: `;`, `end`, `else`, `elseif`, `until`
  - Block terminators: `}`, `)`
  - Start of new statements: keywords like `if`, `while`, `for`, `function`, `local`
  """
  @spec recover_at_statement([token()], Error.t()) :: recovery_result()
  def recover_at_statement(tokens, error) do
    case find_statement_boundary(tokens) do
      {:ok, rest} ->
        {:recovered, rest, [error]}

      :not_found ->
        {:failed, [error]}
    end
  end

  @doc """
  Recovers from an unclosed delimiter by finding the matching closing delimiter.
  """
  @spec recover_unclosed_delimiter([token()], atom(), Error.t()) :: recovery_result()
  def recover_unclosed_delimiter(tokens, delimiter_type, error) do
    closing = closing_delimiter(delimiter_type)

    case find_closing_delimiter(tokens, closing, 1) do
      {:ok, rest} ->
        {:recovered, rest, [error]}

      :not_found ->
        # If we can't find the closing delimiter, try to recover at statement boundary
        recover_at_statement(tokens, error)
    end
  end

  @doc """
  Attempts to recover from missing keyword error.
  """
  @spec recover_missing_keyword([token()], atom(), Error.t()) :: recovery_result()
  def recover_missing_keyword(tokens, keyword, error) do
    case find_keyword(tokens, keyword) do
      {:ok, rest} ->
        {:recovered, rest, [error]}

      :not_found ->
        recover_at_statement(tokens, error)
    end
  end

  @doc """
  Skips tokens until we find a valid statement start.
  """
  @spec skip_to_statement([token()]) :: [token()]
  def skip_to_statement(tokens) do
    case find_statement_boundary(tokens) do
      {:ok, rest} -> rest
      :not_found -> []
    end
  end

  @doc """
  Checks if a token is a statement boundary (synchronization point).
  """
  @spec is_statement_boundary?(token()) :: boolean()
  def is_statement_boundary?(token) do
    case token do
      {:delimiter, :semicolon, _} -> true
      {:keyword, kw, _} when kw in [:end, :else, :elseif, :until] -> true
      {:keyword, kw, _} when kw in [:if, :while, :for, :function, :local, :do, :repeat] -> true
      {:eof, _} -> true
      _ -> false
    end
  end

  defmodule DelimiterStack do
    @moduledoc """
    Tracks unclosed delimiters in a stack-based manner.
    """

    defstruct stack: []

    @type t :: %__MODULE__{stack: [{atom(), Meta.position()}]}

    def new, do: %__MODULE__{}

    def push(stack, delimiter, position) do
      %{stack | stack: [{delimiter, position} | stack.stack]}
    end

    def pop(stack, closing_delimiter) do
      case stack.stack do
        [{opening, _pos} | rest] ->
          if matches?(opening, closing_delimiter) do
            {:ok, %{stack | stack: rest}}
          else
            {:error, :mismatched, opening}
          end

        [] ->
          {:error, :empty}
      end
    end

    def peek(stack) do
      case stack.stack do
        [{delimiter, position} | _] -> {:ok, delimiter, position}
        [] -> :empty
      end
    end

    def empty?(stack), do: stack.stack == []

    defp matches?(opening, closing) do
      case {opening, closing} do
        {:lparen, :rparen} -> true
        {:lbracket, :rbracket} -> true
        {:lbrace, :rbrace} -> true
        {:function, :end} -> true
        {:if, :end} -> true
        {:while, :end} -> true
        {:for, :end} -> true
        {:do, :end} -> true
        _ -> false
      end
    end
  end

  # Private helpers

  defp find_statement_boundary([token | rest]) do
    if is_statement_boundary?(token) do
      {:ok, [token | rest]}
    else
      find_statement_boundary(rest)
    end
  end

  defp find_statement_boundary([]), do: :not_found

  defp find_closing_delimiter([{:delimiter, delim, _} | rest], target, depth)
       when delim == target do
    if depth == 1 do
      {:ok, rest}
    else
      find_closing_delimiter(rest, target, depth - 1)
    end
  end

  defp find_closing_delimiter([{:delimiter, opening, _} | rest], target, depth)
       when opening in [:lparen, :lbracket, :lbrace] do
    find_closing_delimiter(rest, target, depth + 1)
  end

  defp find_closing_delimiter([{:keyword, :end, _} | rest], :end, depth) do
    if depth == 1 do
      {:ok, rest}
    else
      find_closing_delimiter(rest, :end, depth - 1)
    end
  end

  defp find_closing_delimiter([{:keyword, kw, _} | rest], :end, depth)
       when kw in [:if, :while, :for, :function, :do] do
    find_closing_delimiter(rest, :end, depth + 1)
  end

  defp find_closing_delimiter([{:eof, _}], _target, _depth), do: :not_found
  defp find_closing_delimiter([], _target, _depth), do: :not_found

  defp find_closing_delimiter([_ | rest], target, depth) do
    find_closing_delimiter(rest, target, depth)
  end

  defp find_keyword([{:keyword, kw, _} | _rest] = tokens, target) when kw == target do
    {:ok, tokens}
  end

  defp find_keyword([{:eof, _}], _target), do: :not_found
  defp find_keyword([], _target), do: :not_found

  defp find_keyword([_ | rest], target) do
    find_keyword(rest, target)
  end

  defp closing_delimiter(delimiter) do
    case delimiter do
      :lparen -> :rparen
      :lbracket -> :rbracket
      :lbrace -> :rbrace
      _ -> :end
    end
  end
end
