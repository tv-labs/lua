defmodule Mix.Tasks.Lua.Eval do
  @shortdoc "Evaluates a Lua source file (or stdin)"
  @moduledoc """
  Evaluates a Lua source file in a fresh `Lua.new()` VM and prints
  any return values.

  ## Usage

      mix lua.eval path/to/script.lua
      echo "return 1 + 2" | mix lua.eval -

  Pass `-` as the path to read source from stdin. Anything Lua's
  built-in `print()` writes goes to stdout normally; the task's
  printed return values appear after that.

  ## Options

    * `--source NAME` — Source name shown in runtime errors
      (default: the basename of the file, or `<stdin>` when reading
      from `-`).

  ## Exit codes

    * `0` — script ran to completion (even if it returned nothing).
    * `1` — script raised a `Lua.CompilerException` or
      `Lua.RuntimeException`. The error message is written to
      stderr.

  ## Examples

      $ echo "return 1 + 2" | mix lua.eval -
      [3]

      $ mix lua.eval test/fixtures/returns_value.lua
      [5]
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional} = OptionParser.parse!(args, strict: [source: :string])

    {source, source_name} = read_source(positional, opts)

    try do
      {results, _state} = Lua.eval!(Lua.new(), source, source: source_name)
      IO.puts(inspect(results, pretty: true, limit: :infinity, charlists: :as_lists))
    rescue
      e in [Lua.CompilerException, Lua.RuntimeException] ->
        IO.puts(:stderr, Exception.message(e))
        exit({:shutdown, 1})
    end
  end

  defp read_source([], _opts) do
    Mix.raise("usage: mix lua.eval <path|->")
  end

  defp read_source(["-"], opts) do
    name = Keyword.get(opts, :source, "<stdin>")
    {:stdio |> IO.read(:eof) |> to_string(), name}
  end

  defp read_source([path], opts) do
    case File.read(path) do
      {:ok, source} ->
        name = Keyword.get(opts, :source, Path.basename(path))
        {source, name}

      {:error, reason} ->
        Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp read_source(_, _opts) do
    Mix.raise("usage: mix lua.eval <path|->")
  end
end
