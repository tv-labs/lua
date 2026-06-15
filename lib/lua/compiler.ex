defmodule Lua.Compiler do
  @moduledoc """
  Public API for the Lua compiler.

  Transforms Lua AST into executable prototypes.
  """

  alias Lua.AST.Chunk
  alias Lua.Compiler.Bytecode
  alias Lua.Compiler.Codegen
  alias Lua.Compiler.GotoResolution
  alias Lua.Compiler.GotoValidation
  alias Lua.Compiler.Prototype
  alias Lua.Compiler.Scope

  @type compile_opts :: [
          source: binary()
        ]

  @doc """
  Compiles a Lua AST chunk into a prototype.

  After codegen, the prototype is offered to `Lua.Compiler.Bytecode` for
  dense encoding. Sub-prototypes are encoded independently — the dispatcher
  takes over per-prototype wherever every opcode in that prototype falls
  within its coverage; anything else stays on the interpreter. The
  original instruction stream is preserved either way, so error reporting
  and tooling continue to work unchanged.
  """
  @spec compile(Chunk.t(), compile_opts()) :: {:ok, Prototype.t()} | {:error, term()}
  def compile(%Chunk{} = chunk, opts \\ []) do
    with :ok <- GotoValidation.validate(chunk),
         {:ok, scope_state} <- Scope.resolve(chunk, opts),
         {:ok, prototype} <- Codegen.generate(chunk, scope_state, opts) do
      # Encode bytecode first (it reads the raw `:goto` / `:label` stream),
      # then resolve gotos for the list interpreter. The two passes are
      # independent: the dispatcher runs `bytecode`, the interpreter runs the
      # resolved `instructions` plus `goto_targets`.
      prototype =
        prototype
        |> Bytecode.compile()
        |> GotoResolution.resolve()

      {:ok, prototype}
    end
  end

  @doc """
  Compiles a Lua AST chunk, raising on error.
  """
  @spec compile!(Chunk.t(), compile_opts()) :: Prototype.t()
  def compile!(%Chunk{} = chunk, opts \\ []) do
    # Codegen surfaces unsupported constructs by raising directly, but the
    # goto legality pass (`Lua.Compiler.GotoValidation`) returns `{:error,
    # message}` for programs PUC-Lua rejects at compile time. Re-raise those as
    # a clear compiler exception.
    case compile(chunk, opts) do
      {:ok, prototype} -> prototype
      {:error, message} -> raise Lua.CompilerException, message
    end
  end
end
