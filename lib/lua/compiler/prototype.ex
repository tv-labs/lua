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
          upvalue_names: [String.t()],
          param_count: non_neg_integer(),
          is_vararg: boolean(),
          max_registers: non_neg_integer(),
          source: binary(),
          lines: {non_neg_integer(), non_neg_integer()},
          bytecode: tuple() | nil,
          reg_file_size: non_neg_integer()
        }

  # `bytecode` is an optional dense encoding produced by `Lua.Compiler.Bytecode`.
  # When set, the executor routes calls into `Lua.VM.Dispatcher` for a tighter
  # dispatch loop. When nil, the prototype is interpreted in the usual way.
  # The two representations are kept independent so the human-readable
  # `instructions` list (used by error reporting, debugging, and any future
  # tooling) survives untouched.
  #
  # `reg_file_size` is the exact number of registers the dispatcher must
  # allocate to run `bytecode` — the highest register index any encoded op
  # reads or writes, plus one (and never below `param_count`). It is derived
  # from the emitted bytecode in `Lua.Compiler.Bytecode.compile/1`, which is
  # authoritative even where codegen's `max_registers` undercounts the peak;
  # runtime-dynamic expansion (vararg spread, multi-return) grows the tuple
  # on demand in the dispatcher. Sizing to this exact value rather than a
  # blanket slack buffer keeps call-dense code (deep recursion) off a
  # per-call register over-allocation (issue #324). Zero for prototypes that
  # fell back to the interpreter, which sizes its own register file.
  defstruct instructions: [],
            prototypes: [],
            upvalue_descriptors: [],
            upvalue_names: [],
            param_count: 0,
            is_vararg: false,
            max_registers: 0,
            source: <<"-no-source-">>,
            lines: {0, 0},
            varargs: [],
            bytecode: nil,
            reg_file_size: 0

  @doc """
  Creates a new prototype with the given options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
