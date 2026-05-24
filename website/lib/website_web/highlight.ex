defmodule DemoWeb.Highlight do
  @moduledoc """
  Server-rendered syntax highlighting.

  Elixir runs through Makeup (`Makeup.Lexers.ElixirLexer`). Lua uses a
  small hand-rolled tokenizer in this module — `makeup_lua` doesn't
  exist on Hex and the static snippets we render don't need a full
  Lua 5.3 lexer. Both paths emit Pygments-style class names so the
  same CSS in `app.css` styles them.
  """

  @lua_keywords ~w(and break do else elseif end for function goto
                   if in local not or repeat return then until while)

  @lua_kc ~w(true false nil)

  # Matches in priority order. Longest/most-specific patterns first.
  # Each entry is {regex, css_class}. A `nil` class means "no span".
  @lua_patterns [
    {~r/\A--\[\[[\s\S]*?(?:\]\]|\z)/, "cm"},
    {~r/\A--[^\r\n]*/, "c1"},
    {~r/\A"(?:\\.|[^"\\\r\n])*"/, "s2"},
    {~r/\A'(?:\\.|[^'\\\r\n])*'/, "s1"},
    {~r/\A\[\[[\s\S]*?(?:\]\]|\z)/, "s"},
    {~r/\A0[xX][\da-fA-F]+(?:\.[\da-fA-F]*)?(?:[pP][+-]?\d+)?/, "mh"},
    {~r/\A\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, "mf"},
    {~r/\A(?:\.\.\.|\.\.|::|==|~=|<=|>=|<<|>>|\/\/|[+\-*\/%^#=<>~])/, "o"},
    {~r/\A[(){}\[\],;:.]/, "p"},
    {~r/\A[A-Za-z_][A-Za-z0-9_]*/, :ident},
    {~r/\A[\s]+/, nil}
  ]

  @doc """
  Returns inner HTML for `source` highlighted in the given language,
  ready to embed inside `<pre class="highlight">…</pre>`.

  Supported: `:elixir`, `:lua`. Anything else falls back to escaped
  plain text so an unknown language can never crash a page render.
  """
  def to_html(source, language \\ :elixir)

  def to_html(source, :elixir) when is_binary(source) do
    source
    |> Makeup.highlight_inner_html(lexer: Makeup.Lexers.ElixirLexer)
    |> Phoenix.HTML.raw()
  end

  def to_html(source, :lua) when is_binary(source) do
    source
    |> tokenize_lua([])
    |> Phoenix.HTML.raw()
  end

  def to_html(source, _other) when is_binary(source) do
    Phoenix.HTML.html_escape(source)
  end

  defp tokenize_lua("", acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp tokenize_lua(source, acc) do
    {chunk, class, rest} = match_lua(source)
    escaped = chunk |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    fragment =
      case class do
        nil -> escaped
        cls -> [~s(<span class="), cls, ~s(">), escaped, "</span>"]
      end

    tokenize_lua(rest, [fragment | acc])
  end

  defp match_lua(source) do
    Enum.find_value(@lua_patterns, fn {regex, class} ->
      case Regex.run(regex, source, return: :index) do
        [{0, len}] ->
          {chunk, rest} = String.split_at(source, len)
          {chunk, resolve_lua_class(class, chunk), rest}

        _ ->
          nil
      end
    end) || fallback_lua(source)
  end

  defp resolve_lua_class(:ident, chunk) do
    cond do
      chunk in @lua_kc -> "kc"
      chunk in @lua_keywords -> "k"
      true -> "n"
    end
  end

  defp resolve_lua_class(class, _chunk), do: class

  # No pattern matched (e.g. a stray UTF-8 char). Consume one codepoint
  # raw so we make forward progress without blowing up the page.
  defp fallback_lua(source) do
    case String.next_codepoint(source) do
      {cp, rest} -> {cp, nil, rest}
      nil -> {"", nil, ""}
    end
  end
end
