defmodule Website.LuaExamplesTest do
  use ExUnit.Case, async: true

  alias Website.LuaSandbox

  # Lessons marked `runnable: false` (e.g. coroutines) ship a snippet for
  # display but can't execute under the current sandbox. They're covered
  # by the rubric tests below; we just skip them from the run-it loop.
  @runnable_tour Enum.filter(LuaSandbox.tour_lessons(), &Map.get(&1, :runnable, true))

  @all Enum.map(LuaSandbox.home_snippets(), &{"home", &1}) ++
         Enum.map(LuaSandbox.examples(), &{"playground", &1}) ++
         Enum.map(@runnable_tour, &{"tour", &1})

  # Lessons without a `:source` (e.g. the closing "where next" page) are
  # prose-only and have nothing to compile or run.
  for {source, example} <- @all, Map.has_key?(example, :source) do
    @example example
    @expect Map.get(example, :expect, :ok)
    @label "#{source}/#{example[:id] || example[:slug]}"

    test "#{@label} (#{@expect})" do
      result = LuaSandbox.run(@example.source)

      case @expect do
        :ok ->
          assert result.status == :ok,
                 "expected #{@label} to run cleanly, got: #{inspect(result.error)}"

          assert match?({:ok, _chunk, _blocks}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to compile cleanly"

        :compile_error ->
          assert result.status == :error,
                 "expected #{@label} to fail, but it succeeded"

          assert match?({:error, _msgs}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to fail compilation"

        :runtime_error ->
          assert result.status == :error,
                 "expected #{@label} to fail at runtime, but it succeeded"

          assert match?({:ok, _chunk, _blocks}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to compile cleanly (runtime-only failure)"

        :limit ->
          # Resource-limit demos (memory ceiling / wall-clock timeout) compile
          # and start fine, but the run is stopped and reported as a timeout.
          assert result.status == :timeout,
                 "expected #{@label} to hit a resource limit, got: #{inspect(result.status)}"

          assert match?({:ok, _chunk, _blocks}, LuaSandbox.compile(@example.source)),
                 "expected #{@label} to compile cleanly (stopped at runtime)"
      end
    end
  end

  describe "tour rubric" do
    @lessons LuaSandbox.tour_lessons()

    test "every lesson belongs to a known chapter" do
      known = Map.new(LuaSandbox.chapters())

      for lesson <- @lessons do
        assert is_atom(lesson.chapter) and Map.has_key?(known, lesson.chapter),
               "lesson #{lesson.slug} has unknown chapter #{inspect(lesson.chapter)}"
      end
    end

    test "every lesson has a non-empty slug, title, objective, body" do
      for lesson <- @lessons do
        for key <- [:slug, :title, :objective, :body] do
          val = Map.fetch!(lesson, key)

          assert is_binary(val) and val != "",
                 "lesson #{lesson.slug} missing #{key} (got #{inspect(val)})"
        end
      end
    end

    test "every lesson title is <= 32 characters" do
      for %{slug: slug, title: title} <- @lessons do
        assert String.length(title) <= 32,
               "lesson #{slug} title too long (#{String.length(title)}): #{inspect(title)}"
      end
    end

    test "every lesson body is <= 90 words" do
      for %{slug: slug, body: body} <- @lessons do
        words = body |> String.split(~r/\s+/, trim: true) |> length()

        assert words <= 90,
               "lesson #{slug} body has #{words} words (limit 90)"
      end
    end

    test "lesson source is within the chapter's line budget" do
      for lesson <- @lessons,
          source = Map.get(lesson, :source),
          is_binary(source) do
        line_count = source |> String.trim_trailing() |> String.split("\n") |> length()
        limit = if lesson.chapter == :integration, do: 12, else: 18

        assert line_count <= limit,
               "lesson #{lesson.slug} (#{lesson.chapter}) has #{line_count} source lines (limit #{limit})"
      end
    end

    test "every `see_also` slug points at a real lesson" do
      slugs = MapSet.new(@lessons, & &1.slug)

      for lesson <- @lessons,
          ref <- Map.get(lesson, :see_also, []) do
        assert MapSet.member?(slugs, ref),
               "lesson #{lesson.slug} references unknown see_also #{inspect(ref)}"
      end
    end

    test "chapter IV lessons carry an `:elixir_source` companion pane" do
      for lesson <- @lessons, lesson.chapter == :integration do
        assert is_binary(Map.get(lesson, :elixir_source)) and
                 Map.get(lesson, :elixir_source) != "",
               "integration lesson #{lesson.slug} missing :elixir_source"
      end
    end

    test "every named Lua.ex API in chapter IV resolves at runtime" do
      # Catches API drift: if Lua.ex renames or removes one of these
      # symbols, the tour's Chapter IV goes silently stale.
      lua_funcs = [
        {Lua, :new, 0},
        {Lua, :eval!, 2},
        {Lua, :set!, 3},
        {Lua, :get!, 2},
        {Lua, :get!, 3},
        {Lua, :call_function!, 3},
        {Lua, :load_api, 2},
        {Lua, :put_private, 3},
        {Lua, :get_private!, 2}
      ]

      for {mod, fun, arity} <- lua_funcs do
        Code.ensure_loaded(mod)

        assert function_exported?(mod, fun, arity),
               "Lua.ex API drift: #{inspect(mod)}.#{fun}/#{arity} no longer exists"
      end

      # Macros aren't reported by function_exported?, so check separately.
      Code.ensure_loaded(Lua)

      assert macro_exported?(Lua, :sigil_LUA, 2),
             "Lua.ex API drift: Lua.sigil_LUA/2 macro no longer exists"

      Code.ensure_loaded(Lua.API)

      assert macro_exported?(Lua.API, :deflua, 2) or macro_exported?(Lua.API, :deflua, 3),
             "Lua.ex API drift: Lua.API.deflua macro no longer exists"
    end
  end
end
