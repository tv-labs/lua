defmodule Lua.Compiler.Erlang do
  @moduledoc """
  Compiles `Lua.Compiler.Prototype` values to BEAM modules via
  `:compile.forms/2`.

  A compiled prototype gets dispatched through the
  `{:compiled_closure, module, function, upvalues}` value type
  recognised by `Lua.VM.Executor.call_function/3` and the `:call`
  opcode. The compiled function takes `(args, upvalues, state)`
  and returns `{results, state}`.

  ## Scope (B5a — opcode coverage)

  This first revision covers arithmetic, comparison, control flow,
  loops, bitwise ops, string concat/length, source-line tracking,
  calls, single-value returns, and upvalue reads. Prototypes that
  contain table opcodes (B5c), closure construction (B5d), varargs
  (B5d), or multi-value returns (B5d) fall back to the interpreter
  via `:fallback`.

  All-or-nothing per prototype: if any opcode in the instruction
  stream is uncovered, the whole prototype falls back.

  ## Module lifecycle

  Each accepted prototype gets a fresh module name in B5a (leaks).
  B5b introduces a content-addressable ref-counted cache.
  """

  alias Lua.Compiler.Erlang.Codegen
  alias Lua.Compiler.Prototype

  require Logger

  @doc """
  Attempts to compile a prototype (and its sub-prototypes) to BEAM
  modules.

  Returns `{:ok, prototype}` with `:compiled_module` set on the
  returned prototype if the codegen succeeds. Returns `:fallback`
  if any opcode in the prototype (or any sub-prototype) is not yet
  supported by the codegen.

  On a compilation failure (`:compile.forms/2` error,
  `:code.load_binary/3` error), logs a warning and returns
  `:fallback` rather than raising — the caller (the public Lua
  compile path) can then fall back to interpretation.
  """
  @spec compile(Prototype.t()) :: {:ok, Prototype.t()} | :fallback
  def compile(%Prototype{} = proto) do
    # Sub-prototypes compile independently — bottom-up. Each
    # sub-prototype's compile-or-fallback status is set on its
    # `compiled_module` field. The closure-construction opcode in the
    # *parent* checks that field at codegen time and emits either
    # `:compiled_closure` or `:lua_closure` accordingly.
    #
    # This lets a parent compile even if some children don't, and
    # vice versa. The B5a codegen sets up the wiring; B5d's `:closure`
    # opcode lowering picks the right closure type.
    #
    # Returns `{:ok, proto_with_subs_compiled}` even if the parent
    # itself can't compile — the caller still wants the updated
    # sub-prototype tree so interpreter-driven closure construction
    # can emit `:compiled_closure` for sub-prototypes that did compile.
    compiled_subs =
      Enum.map(proto.prototypes, fn sub ->
        {:ok, compiled} = compile(sub)
        compiled
      end)

    proto = %{proto | prototypes: compiled_subs}

    case Codegen.generate(proto) do
      {:ok, module_name, function_name, forms} ->
        load_or_pass_through(module_name, function_name, forms, proto)

      :fallback ->
        # Parent prototype itself isn't covered; pass through with
        # subs intact so the interpreter can still close them as
        # compiled.
        {:ok, proto}
    end
  end

  defp load_or_pass_through(module_name, function_name, forms, proto) do
    case load_module(module_name, function_name, forms, proto) do
      {:ok, _} = ok -> ok
      :fallback -> {:ok, proto}
    end
  end

  defp load_module(module_name, function_name, forms, proto) do
    case :compile.forms(forms, [:return, :no_spawn_compiler_process]) do
      {:ok, ^module_name, binary, _warnings} ->
        beam_path = ~c"#{module_name}.beam"

        case :code.load_binary(module_name, beam_path, binary) do
          {:module, ^module_name} ->
            {:ok, %{proto | compiled_module: {module_name, function_name}}}

          {:error, reason} ->
            Logger.warning(
              "Lua.Compiler.Erlang: load_binary failed for #{inspect(module_name)}: " <>
                inspect(reason)
            )

            :fallback
        end

      error ->
        Logger.warning(
          "Lua.Compiler.Erlang: compile.forms failed for #{inspect(module_name)}: " <>
            inspect(error)
        )

        :fallback
    end
  end
end
