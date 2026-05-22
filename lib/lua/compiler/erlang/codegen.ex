defmodule Lua.Compiler.Erlang.Codegen do
  @moduledoc false
  # Walks a `Lua.Compiler.Prototype` and produces Erlang abstract forms
  # ready for `:compile.forms/2`.
  #
  # Strategy: the compiled function keeps registers in a tuple identical
  # in shape to the interpreter's. Each opcode emits Erlang code that
  # reads from the tuple via `element/2` and writes via `setelement/3`.
  # State threads as a single Erlang variable through every opcode that
  # can mutate it.
  #
  # This is the conservative shape from the parent B5 plan (Option 1,
  # plan line 159-162): keep the register tuple, eat `setelement/3` per
  # write, but eliminate the entire interpreter dispatch loop. The third
  # spike (fib faithful, 12.4x faster than interpreter) used this shape
  # and confirmed the win.
  #
  # SSA register promotion is a follow-on (deferred B5c-style work) and
  # would buy another large chunk on top.

  alias Lua.Compiler.Erlang.Opcodes
  alias Lua.Compiler.Prototype

  # Variable names used in the generated function body. `__` prefixes
  # avoid collisions with anything the codegen might want to introduce
  # later.
  @args_var :__Args
  @upvalues_var :__Upvalues
  @state_var :__State
  @regs_var :__Regs

  defmodule Ctx do
    @moduledoc false
    # Codegen context threaded through every opcode lowering. Each
    # opcode's lowering function returns `{forms, updated_ctx}`.

    defstruct [
      # Counter used to mint fresh helper-function names for loop
      # bodies, labels, etc.
      :next_label,
      # Counter used to mint fresh state variable versions
      # (State_0, State_1, …).
      :next_state_version,
      # Atom for the current state variable name.
      :state_var,
      # Counter used to mint fresh register-tuple variable versions
      # (Regs_0, Regs_1, …).
      :next_regs_version,
      # Atom for the current registers variable name.
      :regs_var,
      # Map of label name → helper function name. Populated as we
      # walk and encounter `:label` opcodes. `:goto` resolves
      # against this map at codegen time, not at runtime.
      :labels,
      # Accumulator for helper function clauses (loop bodies,
      # label targets) that the lowering emits as side-effects of
      # the main walk.
      :helpers,
      # The prototype being compiled — for source position, max_registers,
      # etc.
      :proto,
      # Current source line, updated by `:source_line` opcodes. Used as
      # the `line` arg in calls to `Executor.apply_arith_op` and friends
      # so runtime errors carry the right position.
      :line
    ]

    def new(proto, state_var, regs_var) do
      %__MODULE__{
        next_label: 0,
        next_state_version: 0,
        state_var: state_var,
        next_regs_version: 0,
        regs_var: regs_var,
        labels: %{},
        helpers: [],
        proto: proto,
        line: elem(proto.lines, 0) || 1
      }
    end

    def fresh_state_var(%__MODULE__{next_state_version: n} = ctx) do
      var = String.to_atom("State_#{n}")
      {var, %{ctx | next_state_version: n + 1, state_var: var}}
    end

    def fresh_regs_var(%__MODULE__{next_regs_version: n} = ctx) do
      var = String.to_atom("Regs_#{n}")
      {var, %{ctx | next_regs_version: n + 1, regs_var: var}}
    end

    def fresh_label(%__MODULE__{next_label: n} = ctx, prefix) do
      name = String.to_atom("#{prefix}_#{n}")
      {name, %{ctx | next_label: n + 1}}
    end

    def add_helper(%__MODULE__{helpers: helpers} = ctx, helper_form) do
      %{ctx | helpers: [helper_form | helpers]}
    end
  end

  # Module names use `:erlang.unique_integer/1` so concurrent compiles
  # do not collide. Replaced by content-addressable hashing in B5b.

  @doc """
  Walks a prototype and returns either `{:ok, module, function, forms}`
  ready to feed to `:compile.forms/2`, or `:fallback` if any opcode is
  not yet covered by the codegen.
  """
  @spec generate(Prototype.t()) ::
          {:ok, module(), atom(), list()} | :fallback
  def generate(%Prototype{} = proto) do
    module_name = next_module_name()
    function_name = :execute

    ctx = Ctx.new(proto, @state_var, @regs_var)

    # Separate the tail :return (if present) so it can emit a natural
    # return form, bypassing the throw/catch round-trip. Saves
    # ~half of throws on functions with early-exit branches like fib.
    {body_instructions, tail_return} = split_tail_return(proto.instructions)

    case lower_instructions(body_instructions, ctx) do
      {:ok, body_forms, ctx_after} ->
        tail_form = build_tail_return(tail_return, ctx_after)
        forms = build_module(module_name, function_name, proto, body_forms ++ tail_form, ctx_after)
        {:ok, module_name, function_name, forms}

      :fallback ->
        :fallback
    end
  end

  defp split_tail_return(instructions) do
    case List.last(instructions) do
      {:return, base, 1} ->
        {Enum.drop(instructions, -1), {:return, base, 1}}

      _ ->
        {instructions, nil}
    end
  end

  defp build_tail_return(nil, _ctx), do: []

  defp build_tail_return({:return, base, 1}, %{state_var: state_var, regs_var: regs_var, line: line}) do
    # Direct `{[element(base+1, Regs)], State}` — no throw.
    [
      {:tuple, line,
       [
         {:cons, line, {:call, line, {:atom, line, :element}, [{:integer, line, base + 1}, {:var, line, regs_var}]},
          {nil, line}},
         {:var, line, state_var}
       ]}
    ]
  end

  defp next_module_name do
    n = :erlang.unique_integer([:positive, :monotonic])
    :"lua_proto_b5a_#{n}"
  end

  # Build the full module: attribute headers + the execute/3 function.
  defp build_module(module_name, function_name, %Prototype{} = proto, body_forms, ctx) do
    line = elem(proto.lines, 0) || 1

    function_clauses = [
      build_execute_clause(proto, body_forms, line, ctx)
    ]

    [
      {:attribute, line, :module, module_name},
      {:attribute, line, :export, [{function_name, 3}]}
      | Enum.reverse(ctx.helpers)
    ] ++
      [{:function, line, function_name, 3, function_clauses}]
  end

  defp build_execute_clause(%Prototype{} = proto, body_forms, line, ctx) do
    head_patterns = [
      {:var, line, @args_var},
      {:var, line, @upvalues_var},
      {:var, line, @state_var}
    ]

    prelude = build_register_prelude(proto, line)

    # The body is wrapped in a try/catch that catches `throw/1` payloads
    # of the shape `{:b5_return, Results, State}`. This is how we model
    # Lua's "return from anywhere" semantics in Erlang's
    # expression-oriented language. `:return` opcode forms emit `throw`s
    # (except for a tail-position `:return` which we lift out as a
    # natural return — that's `body_forms`' last element when the
    # generator decided to optimise it).
    #
    # If the body's last form is *not* a return tuple, append the
    # implicit `{[], State_curr}` so a function that falls off the end
    # still has a return value.
    body_block =
      case List.last(body_forms) do
        {:tuple, _, [_cons_or_nil, _state]} ->
          # Last form is a natural-tail return tuple — don't override.
          body_forms

        _ ->
          body_forms ++ [{:tuple, line, [{nil, line}, {:var, line, ctx.state_var}]}]
      end

    try_body = make_block(body_block, line)

    return_var = :__B5ReturnResults
    return_state_var = :__B5ReturnState

    catch_clauses = [
      {:clause, line,
       [
         {:tuple, line,
          [
            {:atom, line, :throw},
            {:tuple, line, [{:atom, line, :b5_return}, {:var, line, return_var}, {:var, line, return_state_var}]},
            {:var, line, :_}
          ]}
       ], [], [{:tuple, line, [{:var, line, return_var}, {:var, line, return_state_var}]}]}
    ]

    try_form =
      {:try, line, [try_body], [], catch_clauses, []}

    {:clause, line, head_patterns, [], prelude ++ [try_form]}
  end

  # Wrap a list of forms in a `begin … end` block to keep them as a
  # single expression. If there's only one form, no wrapping needed.
  defp make_block([single], _line), do: single
  defp make_block(forms, line), do: {:block, line, forms}

  # Builds the initial register tuple `__Regs`.
  #
  # Uses `erlang:make_tuple/2` + `setelement/3` to install the args.
  # Simple and fast for now; B5b-or-later could rework this to share
  # a pre-built nil-tuple constant across calls when max_registers is
  # known at codegen time.
  defp build_register_prelude(%Prototype{} = proto, line) do
    max_regs = proto.max_registers + 16
    param_count = proto.param_count

    init_var = :Regs_init

    make_tuple_call =
      {:call, line, {:remote, line, {:atom, line, :erlang}, {:atom, line, :make_tuple}},
       [{:integer, line, max_regs}, {:atom, line, nil}]}

    init_match = {:match, line, {:var, line, init_var}, make_tuple_call}

    copy_call =
      {:call, line, {:remote, line, {:atom, line, :"Elixir.Lua.Compiler.Erlang.Runtime"}, {:atom, line, :copy_args}},
       [
         {:var, line, @args_var},
         {:var, line, init_var},
         {:integer, line, 0},
         {:integer, line, param_count}
       ]}

    regs_match = {:match, line, {:var, line, @regs_var}, copy_call}

    [init_match, regs_match]
  end

  # Lowers a list of instructions. Returns `{:ok, forms, ctx}` or
  # `:fallback`.
  def lower_instructions(instructions, %Ctx{} = ctx) do
    Enum.reduce_while(instructions, {:ok, [], ctx}, fn instr, {:ok, acc, ctx} ->
      case Opcodes.lower(instr, ctx) do
        {:ok, new_forms, new_ctx} -> {:cont, {:ok, acc ++ new_forms, new_ctx}}
        :fallback -> {:halt, :fallback}
      end
    end)
  end
end
