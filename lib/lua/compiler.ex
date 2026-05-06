defmodule Lua.Compiler do
  @moduledoc """
  Public API for the Lua compiler.

  Transforms Lua AST into executable prototypes.
  """

  alias Lua.AST.Chunk
  alias Lua.Compiler.Codegen
  alias Lua.Compiler.Prototype
  alias Lua.Compiler.Scope

  @type compile_opts :: [
          source: binary()
        ]

  @doc """
  Compiles a Lua AST chunk into a prototype.
  """
  @spec compile(Chunk.t(), compile_opts()) :: {:ok, Prototype.t()} | {:error, term()}
  def compile(%Chunk{} = chunk, opts \\ []) do
    with {:ok, scope_state} <- Scope.resolve(chunk, opts) do
      Codegen.generate(chunk, scope_state, opts)
    end
  end

  @doc """
  Compiles a Lua AST chunk, raising on error.
  """
  @spec compile!(Chunk.t(), compile_opts()) :: Prototype.t()
  def compile!(%Chunk{} = chunk, opts \\ []) do
    # `compile/2`'s spec allows `{:error, _}` for forward compatibility, but the
    # codegen path doesn't yet have an error-returning code path — codegen
    # surfaces unsupported constructs by raising directly. Once codegen is
    # converted to thread `{:ok, _} | {:error, _}` through every clause, swap
    # this back to a `case` that re-raises `{:error, reason}` as a clear
    # compiler exception.
    {:ok, prototype} = compile(chunk, opts)
    prototype
  end
end
