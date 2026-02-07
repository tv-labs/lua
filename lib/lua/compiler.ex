defmodule Lua.Compiler do
  @moduledoc """
  Public API for the Lua compiler.

  Transforms Lua AST into executable prototypes.
  """

  alias Lua.AST.Chunk
  alias Lua.Compiler.{Scope, Codegen, Prototype}

  @type compile_opts :: [
          source: binary()
        ]

  @doc """
  Compiles a Lua AST chunk into a prototype.
  """
  @spec compile(Chunk.t(), compile_opts()) :: {:ok, Prototype.t()} | {:error, term()}
  def compile(%Chunk{} = chunk, opts \\ []) do
    with {:ok, scope_state} <- Scope.resolve(chunk, opts),
         {:ok, prototype} <- Codegen.generate(chunk, scope_state, opts) do
      {:ok, prototype}
    end
  end

  @doc """
  Compiles a Lua AST chunk, raising on error.
  """
  @spec compile!(Chunk.t(), compile_opts()) :: Prototype.t()
  def compile!(%Chunk{} = chunk, opts \\ []) do
    case compile(chunk, opts) do
      {:ok, prototype} -> prototype
      {:error, reason} -> raise "Compilation failed: #{inspect(reason)}"
    end
  end
end
