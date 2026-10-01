defmodule Lua.VM.Int64WrapEnginesTest do
  @moduledoc """
  Pins integer `+`, `-` and `*` at the int64 boundaries (Lua 5.3 §3.4.1:
  integer arithmetic wraps around modulo 2^64) under both execution engines.

  Operands come in as function parameters so nothing is constant-folded.
  `f` exercises the register forms (`:add` / `:subtract` / `:multiply`);
  `g` exercises the constant forms the peephole fuses (`:add_k` /
  `:subtract_k` / `:multiply_k`). Cases sit on both sides of the int64
  bounds and of the BEAM small-integer bound (2^59), and mix in floats,
  which must never take the wrapping path.

  Each case runs under both execution engines: the default compile path
  (closures carry bytecode and run on the dispatcher) and with bytecode
  recursively stripped (closures run on the instruction interpreter).
  """
  use ExUnit.Case, async: true

  alias Lua.Compiler
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Prototype
  alias Lua.Parser
  alias Lua.VM
  alias Lua.VM.State
  alias Lua.VM.Stdlib

  @max 0x7FFFFFFFFFFFFFFF
  @min -0x8000000000000000
  @small 0x7FFFFFFFFFFFFFF

  @source """
  local function f(a, b) return a + b, a - b, a * b end
  local function g(a) return a + 1, a - 1, a * 2 end
  return f, g
  """

  # {a, b, [a + b, a - b, a * b]}
  @register_cases [
    {@max, 1, [@min, @max - 1, @max]},
    {@min, 1, [@min + 1, @max, @min]},
    {@min, -1, [@max, @min + 1, @min]},
    {@max, @max, [-2, 0, 1]},
    {@min, @min, [0, 0, 0]},
    {@max, @min, [-1, -1, @min]},
    {@max, 2, [@min + 1, @max - 2, -2]},
    {0x4000000000000000, 2, [0x4000000000000002, 0x3FFFFFFFFFFFFFFE, @min]},
    {0x80000000, 0x100000000, [0x180000000, -0x80000000, @min]},
    {@small, 1, [@small + 1, @small - 1, @small]},
    {-@small - 1, -1, [-@small - 2, -@small, @small + 1]},
    {@small, @small, [2 * @small, 0, -0x1000000000000000 + 1]},
    {@max, 1.0, [@max + 1.0, @max - 1.0, @max * 1.0]},
    {@min, -1.0, [@min - 1.0, @min + 1.0, -(@min * 1.0)]},
    {1, 0.5, [1.5, 0.5, 0.5]}
  ]

  # {a, [a + 1, a - 1, a * 2]}
  @constant_cases [
    {@max, [@min, @max - 1, -2]},
    {@min, [@min + 1, @max, 0]},
    {0x4000000000000000, [0x4000000000000001, 0x3FFFFFFFFFFFFFFF, @min]},
    {@small, [@small + 1, @small - 1, 2 * @small]},
    {-@small - 1, [-@small, -@small - 2, -2 * @small - 2]},
    {1.5, [2.5, 0.5, 3.0]},
    {@max * 1.0, [@max + 1.0, @max - 1.0, @max * 2.0]}
  ]

  defp functions(engine) do
    {:ok, ast} = Parser.parse(@source)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")

    proto =
      case engine do
        :compiled -> proto
        :interpreted -> strip_bytecode(proto)
      end

    state = Stdlib.install(State.new())
    {:ok, [f, g], state} = VM.execute(proto, state)
    {f, g, state}
  end

  defp call(fun, args, state) do
    {results, _state} = VM.Executor.call_function(fun, args, state)
    results
  end

  defp strip_bytecode(%Prototype{} = proto) do
    %{proto | bytecode: nil, prototypes: Enum.map(proto.prototypes, &strip_bytecode/1)}
  end

  # `===` keeps an integer result from passing for a float one, and back.
  defp assert_same(actual, expected, label) do
    assert length(actual) == length(expected), label

    for {a, e} <- Enum.zip(actual, expected) do
      assert a === e, "#{label}: got #{inspect(actual)}, expected #{inspect(expected)}"
    end
  end

  for engine <- [:compiled, :interpreted] do
    @engine engine

    describe "int64 wrapping (#{engine} engine)" do
      test "register forms: a + b, a - b, a * b" do
        {f, _g, state} = functions(@engine)

        for {a, b, expected} <- @register_cases do
          assert_same(call(f, [a, b], state), expected, "f(#{inspect(a)}, #{inspect(b)})")
        end
      end

      test "constant forms: a + 1, a - 1, a * 2" do
        {_f, g, state} = functions(@engine)

        for {a, expected} <- @constant_cases do
          assert_same(call(g, [a], state), expected, "g(#{inspect(a)})")
        end
      end
    end
  end

  test "the compiled path encodes every form under test" do
    {:ok, ast} = Parser.parse(@source)
    {:ok, proto} = Compiler.compile(ast, source: "test.lua")
    assert Bytecode.fully_compiled?(proto)

    tags = for p <- proto.prototypes, op <- Tuple.to_list(p.bytecode), do: elem(op, 0)

    for op <- [
          Bytecode.op_add(),
          Bytecode.op_subtract(),
          Bytecode.op_multiply(),
          Bytecode.op_add_k(),
          Bytecode.op_subtract_k(),
          Bytecode.op_multiply_k()
        ] do
      assert op in tags
    end
  end
end
