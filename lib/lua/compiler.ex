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

  Prototypes that the Erlang codegen can handle (see
  `Lua.Compiler.Erlang`) are returned with `compiled_module:` set
  and dispatched directly to a BEAM module at runtime. Prototypes
  containing opcodes not yet covered by the codegen fall back to
  interpretation transparently.
  """
  @spec compile(Chunk.t(), compile_opts()) :: {:ok, Prototype.t()} | {:error, term()}
  def compile(%Chunk{} = chunk, opts \\ []) do
    with {:ok, scope_state} <- Scope.resolve(chunk, opts),
         {:ok, prototype} <- Codegen.generate(chunk, scope_state, opts) do
      {:ok, maybe_compile_to_erlang(prototype)}
    end
  end

  defp maybe_compile_to_erlang(%Prototype{} = proto) do
    {:ok, compiled} = Lua.Compiler.Erlang.compile(proto)
    compiled
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
