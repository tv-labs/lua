defmodule Mix.Tasks.Lua.EvalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lua.Eval

  describe "run/1 with a file path" do
    test "prints the return values of a Lua file" do
      output =
        capture_io(fn ->
          Eval.run(["test/fixtures/returns_value.lua"])
        end)

      assert output =~ "[5]"
    end

    test "captures Lua print() output before the result" do
      path = Path.join(System.tmp_dir!(), "mix_lua_eval_print.lua")
      File.write!(path, ~s|print("hi from lua")\nreturn 42\n|)

      try do
        output =
          capture_io(fn ->
            Eval.run([path])
          end)

        # print() and result both go to stdout; the print line comes first.
        assert output =~ "hi from lua"
        assert output =~ "[42]"

        ["hi from lua", _ | _] = String.split(output, "\n", trim: true)
      after
        File.rm(path)
      end
    end

    test "raises Mix error for missing file" do
      assert_raise Mix.Error, ~r/could not read/, fn ->
        Eval.run(["definitely_not_a_real_file_3491.lua"])
      end
    end
  end

  describe "run/1 with stdin" do
    test "evaluates source read from stdin and prints the result" do
      output =
        capture_io("return 1 + 2", fn ->
          Eval.run(["-"])
        end)

      assert output =~ "[3]"
    end

    test "treats empty stdin as empty source (prints empty list)" do
      output =
        capture_io("", fn ->
          Eval.run(["-"])
        end)

      assert output =~ "[]"
    end

    test "honours --source option for error attribution" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io("return notdefined()", fn ->
            assert catch_exit(Eval.run(["-", "--source", "my_script.lua"])) ==
                     {:shutdown, 1}
          end)
        end)

      assert stderr =~ "my_script.lua"
    end
  end

  describe "argument validation" do
    test "raises Mix error when no path is provided" do
      assert_raise Mix.Error, ~r/usage:/, fn -> Eval.run([]) end
    end

    test "raises Mix error when too many positional args are provided" do
      assert_raise Mix.Error, ~r/usage:/, fn ->
        Eval.run(["foo.lua", "bar.lua"])
      end
    end
  end

  describe "Lua error handling" do
    test "exits 1 with the error message on a runtime error" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io("return notdefined()", fn ->
            assert catch_exit(Eval.run(["-"])) == {:shutdown, 1}
          end)
        end)

      assert stderr =~ "runtime error"
    end

    test "exits 1 on a compile error" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io("local =;", fn ->
            assert catch_exit(Eval.run(["-"])) == {:shutdown, 1}
          end)
        end)

      assert stderr =~ "compile"
    end
  end
end
