defmodule Lua.Compiler.Prototype do
  @moduledoc """
  Represents a compiled Lua function prototype.

  This is the unit of compilation - each Lua function compiles to a prototype
  containing its instructions, nested function prototypes, and upvalue descriptors.
  """

  @type instruction :: tuple()

  @type upvalue_descriptor ::
          {:parent_register, register_index :: non_neg_integer()}
          | {:parent_upvalue, upvalue_index :: non_neg_integer()}

  @type t :: %__MODULE__{
          instructions: [instruction()],
          prototypes: [t()],
          upvalue_descriptors: [upvalue_descriptor()],
          param_count: non_neg_integer(),
          is_vararg: boolean(),
          max_registers: non_neg_integer(),
          source: binary(),
          lines: {non_neg_integer(), non_neg_integer()}
        }

  defstruct instructions: [],
            prototypes: [],
            upvalue_descriptors: [],
            param_count: 0,
            is_vararg: false,
            max_registers: 0,
            source: <<"-no-source-">>,
            lines: {0, 0}

  @doc """
  Creates a new prototype with the given options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
