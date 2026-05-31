defmodule Lua.ErrorGalleryTest do
  @moduledoc """
  Locks the user-visible rendered output for every error category a Lua
  program can hit. Each case evaluates a snippet, captures the public
  `Exception.message/1`, and compares it to a checked-in fixture under
  `test/fixtures/error_gallery/`.

  Fixtures are plain text: the suite runs with ANSI disabled, so the
  committed output is stable across terminals. Regenerate intentionally
  with `GALLERY_REGEN=1 mix test test/lua/error_gallery_test.exs` when the
  format changes on purpose.
  """

  use ExUnit.Case, async: true

  @fixture_dir Path.join([__DIR__, "..", "fixtures", "error_gallery"])

  # {fixture name, lua source, eval opts}. A finite max_call_depth is set on
  # the stack-overflow case so the recursion terminates deterministically.
  @cases [
    {"arithmetic_on_non_number", "local x = nil\nprint(x + 1)", []},
    {"index_nil", "local t = nil\nprint(t.field)", []},
    {"call_nil", "local f = nil\nf()", []},
    {"concat_non_string", "local t = {}\nprint(t .. \"x\")", []},
    {"compare_incompatible", "print(1 < \"x\")", []},
    {"stdlib_bad_arg", "string.upper(nil)", []},
    {"assert_with_message", "assert(false, \"boom\")", []},
    {"assert_no_message", "assert(false)", []},
    {"error_string", "error(\"something broke\")", []},
    {"error_table", "error({code = 1})", []},
    {"stack_overflow", "local function f(n) return 1 + f(n + 1) end\nf(1)", [max_call_depth: 30]}
  ]

  setup do
    refute IO.ANSI.enabled?(), "gallery fixtures assume ANSI is disabled in the test env"
    :ok
  end

  for {name, source, opts} <- @cases do
    test "gallery: #{name}" do
      name = unquote(name)
      source = unquote(source)
      opts = unquote(opts)

      rendered = render(source, opts)
      path = Path.join(@fixture_dir, name <> ".txt")

      if System.get_env("GALLERY_REGEN") == "1" do
        File.mkdir_p!(@fixture_dir)
        File.write!(path, fixture_body(name, source, rendered))
      end

      assert File.exists?(path),
             "missing fixture #{path}; regenerate with GALLERY_REGEN=1"

      expected = path |> File.read!() |> extract_output()

      assert rendered == expected, """
      Rendered output for #{name} drifted from its fixture.
      If this change is intentional, regenerate with:
          GALLERY_REGEN=1 mix test test/lua/error_gallery_test.exs

      --- rendered ---
      #{rendered}
      --- fixture ---
      #{expected}
      """
    end
  end

  defp render(source, opts) do
    lua = Lua.new(opts)

    try do
      Lua.eval!(lua, source, source: "gallery.lua")
      flunk("expected #{inspect(source)} to raise")
    rescue
      e -> Exception.message(e)
    end
  end

  defp fixture_body(name, source, rendered) do
    """
    === category: #{name} ===
    === source ===
    #{source}
    === expected output ===
    #{rendered}
    """
  end

  defp extract_output(contents) do
    [_, output] = String.split(contents, "=== expected output ===\n", parts: 2)
    String.trim_trailing(output, "\n")
  end
end
