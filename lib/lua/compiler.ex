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
    {:ok, prototype} = compile(chunk, opts)
    prototype
    # TODO bring back when the compiler can return errors 
    # {:error, reason} -> raise "Compilation failed: #{inspect(reason)}"
  end
end
