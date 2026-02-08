defmodule Lua do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @type t :: %__MODULE__{}

  # Compiler.compile/1 currently always succeeds but the spec allows {:error, _}
  # for future-proofing. Suppress dialyzer warnings on those defensive branches.
  @dialyzer {:no_match, eval!: 2, eval!: 3, parse_chunk: 1}

  defstruct [:state]

  alias Lua.Util
  alias Lua.VM.{State, Value}

  @default_sandbox [
    [:io],
    [:file],
    [:os, :execute],
    [:os, :exit],
    [:os, :getenv],
    [:os, :remove],
    [:os, :rename],
    [:os, :tmpname],
    [:package],
    [:load],
    [:loadfile],
    [:require],
    [:dofile],
    [:loadstring]
  ]

  defimpl Inspect do
    def inspect(_lua, _opts) do
      "#Lua<>"
    end
  end

  @doc """
  Initializes a Lua VM sandbox

      iex> Lua.new()

  By default, the following Lua functions are sandboxed.

  #{Enum.map_join(@default_sandbox, "\n", fn func -> "* `#{inspect(func)}`" end)}

  To disable, use the `sandboxed` option, passing an empty list

      iex> Lua.new(sandboxed: [])

  Alternatively, you can pass your own list of functions to sandbox. This is equivalent to calling
  `Lua.sandbox/2`.

      iex> Lua.new(sandboxed: [[:os, :exit]])


  ## Options
  * `:sandboxed` - list of paths to be sandboxed, e.g. `sandboxed: [[:require], [:os, :exit]]`
  * `:exclude` - list of paths to exclude from the sandbox, e.g. `exclude: [[:require], [:package]]`
  """
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, sandboxed: @default_sandbox, exclude: [])
    exclude = Keyword.fetch!(opts, :exclude)

    state = State.new() |> Lua.VM.Stdlib.install()

    opts
    |> Keyword.fetch!(:sandboxed)
    |> Enum.reject(fn path -> path in exclude end)
    |> Enum.reduce(%__MODULE__{state: state}, &sandbox(&2, &1))
  end

  @doc """
  Write Lua code that is parsed at compile-time.

      iex> ~LUA"return 2 + 2"
      "return 2 + 2"

  If the code cannot be lexed and parsed, it raises a `Lua.CompilerException`

      #iex> ~LUA":not_lua"
      ** (Lua.CompilerException) Failed to compile Lua!

  As an optimization, the `c` modifier can be used to return a pre-compiled Lua chunk

      iex> ~LUA"return 2 + 2"c
  """
  defmacro sigil_LUA(code, opts) do
    code =
      case code do
        {:<<>>, _, [literal]} -> literal
        _ -> raise "~Lua only accepts string literals, received:\n\n#{Macro.to_string(code)}"
      end

    chunk =
      case Lua.Parser.parse(code) do
        {:ok, ast} ->
          proto = Lua.Compiler.compile!(ast)
          %Lua.Chunk{prototype: proto}

        {:error, msg} ->
          raise Lua.CompilerException, msg
      end

    case opts do
      [?c] -> Macro.escape(chunk)
      _ -> code
    end
  end

  @doc """
  Sandboxes the given path, swapping out the implementation with
  a function that raises when called

      iex> lua = Lua.new(sandboxed: [])
      iex> Lua.sandbox(lua, [:os, :exit])

  """
  def sandbox(lua, path) do
    set!(lua, path, fn args ->
      raise Lua.RuntimeException,
            "#{Lua.Util.format_function(path, Enum.count(args))} is sandboxed"
    end)
  end

  @doc """
  Sets the path patterns that the VM will look in when requiring Lua scripts. For example,
  if you store Lua files in your application's priv directory:

      #iex> lua = Lua.new(exclude: [[:package], [:require]])
      #iex> Lua.set_lua_paths(lua, ["myapp/priv/lua/?.lua", "myapp/lua/?/init.lua"])

  Now you can use the [Lua require](https://www.lua.org/pil/8.1.html) function to import
  these scripts

  > #### Warning {: .warning}
  > In order to use `Lua.set_lua_paths/2`, the following functions cannot be sandboxed:
  > * `[:package]`
  > * `[:require]`
  >
  > By default these are sandboxed, see the `:exclude` option in `Lua.new/1` to allow them.

  > #### Not Yet Implemented {: .warning}
  > `require` and `package` support is not yet implemented in the new VM.
  > This function will raise an error until support is added.
  """
  # TODO: Restore original implementation once require/package support is added:
  #
  #   def set_lua_paths(%__MODULE__{} = lua, paths) when is_list(paths) do
  #     set_lua_paths(lua, Enum.join(paths, ";"))
  #   end
  #
  #   def set_lua_paths(%__MODULE__{} = lua, paths) when is_binary(paths) do
  #     set!(lua, ["package", "path"], paths)
  #   end
  def set_lua_paths(%__MODULE__{} = _lua, _paths) do
    raise Lua.RuntimeException, "set_lua_paths is not yet supported in the new VM"
  end

  @doc """
  Sets a table value in Lua. Nested keys will allocate
  intermediate tables

      iex> Lua.set!(Lua.new(), [:hello], "World")

  It can also set nested values

      iex> Lua.set!(Lua.new(), [:a, :b, :c], [])

  These table values are availble in Lua scripts

      iex> lua = Lua.set!(Lua.new(), [:a, :b, :c], "nested!")
      iex> {result, _} = Lua.eval!(lua, "return a.b.c")
      iex> result
      ["nested!"]

  `Lua.set!/3` can also be used to expose Elixir functions

      iex> lua = Lua.set!(Lua.new(), [:sum], fn args -> [Enum.sum(args)] end)
      iex> {[10], _lua} = Lua.eval!(lua, "return sum(1, 2, 3, 4)")


  Functions can also take a second argument for the state of Lua

      iex> lua =
      ...>   Lua.set!(Lua.new(), [:set_count], fn args, state ->
      ...>     {[], Lua.set!(state, :count, Enum.count(args))}
      ...>   end)
      iex> {[3], _} = Lua.eval!(lua, "set_count(1, 2, 3); return count")

  """
  def set!(%__MODULE__{}, [], _) do
    raise Lua.RuntimeException, "Lua.set!/3 cannot have empty keys"
  end

  def set!(%__MODULE__{} = lua, keys, func) when is_function(func, 1) do
    keys = keys |> List.wrap() |> Enum.map(&to_lua_key/1)

    wrapped =
      {:native_func,
       fn args, state ->
         return = List.wrap(func.(args))

         if not Util.list_encoded?(return) do
           {function_name, scope} = List.pop_at(keys, -1)

           raise Lua.RuntimeException,
             function: function_name,
             scope: scope,
             message: "deflua functions must return encoded data, got #{inspect(return)}"
         end

         {return, state}
       end}

    state = do_set_nested(lua.state, keys, wrapped)
    %{lua | state: state}
  end

  def set!(%__MODULE__{} = lua, keys, func) when is_function(func, 2) do
    keys = keys |> List.wrap() |> Enum.map(&to_lua_key/1)

    wrapped =
      {:native_func,
       fn args, state ->
         {function_name, scope} = List.pop_at(keys, -1)

         case func.(args, wrap(state)) do
           {:error, reason, %__MODULE__{}} ->
             raise Lua.VM.RuntimeError, value: reason

           {value, %__MODULE__{} = lua} ->
             value = List.wrap(value)

             if not Util.list_encoded?(value) do
               raise Lua.RuntimeException,
                 function: function_name,
                 scope: scope,
                 message: "deflua functions must return encoded data, got #{inspect(value)}"
             end

             {value, lua.state}

           value ->
             value = List.wrap(value)

             if not Util.list_encoded?(value) do
               raise Lua.RuntimeException,
                 function: function_name,
                 scope: scope,
                 message: "deflua functions must return encoded data, got #{inspect(value)}"
             end

             {value, state}
         end
       end}

    state = do_set_nested(lua.state, keys, wrapped)
    %{lua | state: state}
  end

  def set!(%__MODULE__{} = lua, keys, value) do
    keys = keys |> List.wrap() |> Enum.map(&to_lua_key/1)

    {encoded, state} =
      if Util.encoded?(value) do
        {value, lua.state}
      else
        Value.encode(value, lua.state)
      end

    state = do_set_nested(state, keys, encoded)
    %{lua | state: state}
  end

  # Sets a value at a nested key path, auto-allocating intermediate tables
  defp do_set_nested(state, [key], value) do
    State.set_global(state, key, value)
  end

  defp do_set_nested(state, [first | rest], value) do
    # Get or allocate the table at the first key
    case Map.get(state.globals, first) do
      {:tref, _} = tref ->
        state = set_in_table(state, tref, rest, value)
        state

      nil ->
        # Allocate intermediate table and recurse
        {tref, state} = State.alloc_table(state)
        state = State.set_global(state, first, tref)
        set_in_table(state, tref, rest, value)

      _other ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([first | rest], ".")}, state}
    end
  end

  # Sets a value inside nested tables, creating intermediates as needed
  defp set_in_table(state, tref, [key], value) do
    State.update_table(state, tref, fn table ->
      %{table | data: Map.put(table.data, key, value)}
    end)
  end

  defp set_in_table(state, tref, [key | rest], value) do
    table = State.get_table(state, tref)

    case Map.get(table.data, key) do
      {:tref, _} = child_tref ->
        set_in_table(state, child_tref, rest, value)

      nil ->
        {child_tref, state} = State.alloc_table(state)

        state =
          State.update_table(state, tref, fn table ->
            %{table | data: Map.put(table.data, key, child_tref)}
          end)

        set_in_table(state, child_tref, rest, value)

      _other ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([key | rest], ".")}, state}
    end
  end

  @doc """
  Gets a table value in Lua

      iex> state = Lua.set!(Lua.new(), [:hello], "world")
      iex> Lua.get!(state, [:hello])
      "world"

  When a value doesn't exist, it returns nil

      iex> Lua.get!(Lua.new(), [:nope])
      nil

  It can also get nested values

      iex> state = Lua.set!(Lua.new(), [:a, :b, :c], "nested")
      iex> Lua.get!(state, [:a, :b, :c])
      "nested"

  ### Options
  * `:decode` - (default `true`) - By default, values are decoded
  """
  def get!(%__MODULE__{state: state}, keys, opts \\ []) when is_list(keys) do
    opts = Keyword.validate!(opts, decode: true)

    keys = Enum.map(keys, &to_lua_key/1)
    value = do_get_nested(state, keys)

    if opts[:decode] do
      Value.decode(value, state)
    else
      value
    end
  end

  defp do_get_nested(state, [key]) do
    Map.get(state.globals, key)
  end

  defp do_get_nested(state, [first | rest]) do
    case Map.get(state.globals, first) do
      {:tref, _} = tref ->
        get_in_table(state, tref, rest)

      nil ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([first | rest], ".")}, state}

      _other ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([first | rest], ".")}, state}
    end
  end

  defp get_in_table(state, tref, [key]) do
    table = State.get_table(state, tref)
    Map.get(table.data, key)
  end

  defp get_in_table(state, tref, [key | rest]) do
    table = State.get_table(state, tref)

    case Map.get(table.data, key) do
      {:tref, _} = child_tref ->
        get_in_table(state, child_tref, rest)

      nil ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([key | rest], ".")}, state}

      _other ->
        raise Lua.RuntimeException,
              {:lua_error, {:illegal_index, nil, Enum.join([key | rest], ".")}, state}
    end
  end

  @doc """
  Evaluates the Lua script, returning any returned values and the updated
  Lua environment

      iex> {[42], _} = Lua.eval!(Lua.new(), "return 42")


  `eval!/2` can also evaluate chunks by passing instead of a script. As a
  performance optimization, it is recommended to call `load_chunk!/2` if you
  will be executing a chunk many times, but it is not necessary.

      iex> {[4], _} = Lua.eval!(~LUA[return 2 + 2]c)


  ### Options
  * `:decode` - (default `true`) By default, all values returned from Lua scripts are decoded.
                This may not be desirable if you need to modify a table reference or access a function call.
                Pass `decode: false` as an option to return encoded values
  """
  def eval!(script) do
    eval!(new(), script, [])
  end

  def eval!(script, opts) when is_binary(script) or is_struct(script, Lua.Chunk) do
    eval!(new(), script, opts)
  end

  def eval!(%__MODULE__{} = lua, script) do
    eval!(lua, script, [])
  end

  def eval!(%__MODULE__{state: state} = lua, script, opts) when is_binary(script) do
    opts = Keyword.validate!(opts, decode: true)

    case Lua.Parser.parse(script) do
      {:ok, ast} ->
        case Lua.Compiler.compile(ast) do
          {:ok, proto} ->
            {:ok, results, new_state} = Lua.VM.execute(proto, state)

            results =
              if opts[:decode] do
                Value.decode_list(results, new_state)
              else
                results
              end

            {results, %{lua | state: new_state}}

          {:error, msg} ->
            raise Lua.CompilerException, msg
        end

      {:error, msg} ->
        raise Lua.CompilerException, msg
    end
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      reraise e, __STACKTRACE__

    e in [Lua.VM.RuntimeError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e in [Lua.VM.TypeError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e in [Lua.VM.AssertionError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e ->
      reraise Lua.RuntimeException, e, __STACKTRACE__
  end

  def eval!(%__MODULE__{state: state} = lua, %Lua.Chunk{prototype: proto}, opts) do
    opts = Keyword.validate!(opts, decode: true)

    {:ok, results, new_state} = Lua.VM.execute(proto, state)

    results =
      if opts[:decode] do
        Value.decode_list(results, new_state)
      else
        results
      end

    {results, %{lua | state: new_state}}
  rescue
    e in [Lua.RuntimeException, Lua.CompilerException] ->
      reraise e, __STACKTRACE__

    e in [Lua.VM.RuntimeError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e in [Lua.VM.TypeError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e in [Lua.VM.AssertionError] ->
      reraise Lua.RuntimeException, Exception.message(e), __STACKTRACE__

    e ->
      reraise Lua.RuntimeException, e, __STACKTRACE__
  end

  @doc """
  Parses a chunk of Lua code into a `t:Lua.Chunk.t/0`, which then can
  be loaded via `load_chunk!/2` or run via `eval!`.

  This function is particularly useful for checking Lua code for syntax
  erorrs and warnings at runtime. If you would like to just load a chunk,
  use `load_chunk!/1` instead.

      iex> {:ok, %Lua.Chunk{}} = Lua.parse_chunk("local foo = 1")

  Errors found during parsing will be returned as a list of formatted strings

      <!-- Old Luerl error format: Lua.parse_chunk("local foo =;") returned {:error, ["Line 1: syntax error before: ';'"]} -->

      iex> {:error, [msg]} = Lua.parse_chunk("local foo =;")
      iex> msg =~ "Expected expression"
      true

  """
  def parse_chunk(code) do
    case Lua.Parser.parse(code) do
      {:ok, ast} ->
        case Lua.Compiler.compile(ast) do
          {:ok, proto} ->
            {:ok, %Lua.Chunk{prototype: proto}}

          {:error, msg} ->
            {:error, List.wrap(msg)}
        end

      {:error, msg} ->
        {:error, List.wrap(msg)}
    end
  end

  @doc """
  Loads string or `t:Lua.Chunk.t/0` into state so that it can be
  evaluated via `eval!/2`

  Strings can be loaded as chunks, which are parsed and loaded

      iex> {%Lua.Chunk{}, %Lua{}} = Lua.load_chunk!(Lua.new(), "return 2 + 2")

  Or a pre-compiled chunk can be loaded as well. In the old Luerl-backed implementation,
  loaded chunks were marked as loaded so they wouldn't be re-loaded on each `eval!/2` call.
  With the new VM, chunks hold a compiled prototype and don't need a separate loading step.

      iex> {%Lua.Chunk{}, %Lua{}} = Lua.load_chunk!(Lua.new(), ~LUA[return 2 + 2]c)
  """
  def load_chunk!(%__MODULE__{} = lua, code) when is_binary(code) do
    case parse_chunk(code) do
      {:ok, chunk} -> {chunk, lua}
      {:error, errors} -> raise Lua.CompilerException, formatted: errors
    end
  end

  def load_chunk!(%__MODULE__{} = lua, %Lua.Chunk{} = chunk) do
    {chunk, lua}
  end

  @doc """
  Calls a function in Lua's state

      # TODO: Restore once string stdlib is implemented
      #iex> {:ok, [ret], _lua} = Lua.call_function(Lua.new(), [:string, :lower], ["HELLO ROBERT"])
      #iex> ret
      #"hello robert"

      iex> lua = Lua.new()
      iex> lua = Lua.set!(lua, [:double], fn [val] -> [val * 2] end)
      iex> {:ok, [_ret], _lua} = Lua.call_function(lua, [:double], [5])

  References to functions can also be passed

      # TODO: Restore once string stdlib is implemented
      #iex> {[ref], lua} = Lua.eval!("return string.lower", decode: false)
      #iex> {:ok, [ret], _lua} = Lua.call_function(lua, ref, ["FUNCTION REF"])
      #iex> ret
      #"function ref"

      iex> {[ref], lua} = Lua.eval!(Lua.new(), "return function(x) return x end", decode: false)
      iex> {:ok, [ret], _lua} = Lua.call_function(lua, ref, [42])
      iex> ret
      42

  """
  def call_function(%__MODULE__{state: state} = lua, func, args)
      when is_tuple(func) do
    case do_call_function(func, args, state) do
      {:ok, results, new_state} -> {:ok, results, %{lua | state: new_state}}
      {:error, reason, new_state} -> {:error, reason, %{lua | state: new_state}}
    end
  end

  def call_function(%__MODULE__{} = lua, name, args) when is_function(name) do
    {ref, lua} = encode!(lua, name)

    case do_call_function(ref, args, lua.state) do
      {:ok, results, new_state} -> {:ok, results, %{lua | state: new_state}}
      {:error, reason, new_state} -> {:error, reason, %{lua | state: new_state}}
    end
  end

  def call_function(%__MODULE__{} = lua, name, args) do
    keys = name |> List.wrap() |> Enum.map(&to_lua_key/1)
    func = do_get_nested(lua.state, keys)

    if func == nil or not is_tuple(func) do
      {:error, "undefined function '#{inspect(func)}'", lua}
    else
      case do_call_function(func, args, lua.state) do
        {:ok, results, new_state} -> {:ok, results, %{lua | state: new_state}}
        {:error, reason, new_state} -> {:error, reason, %{lua | state: new_state}}
      end
    end
  end

  defp do_call_function({:native_func, fun}, args, state) do
    {results, new_state} = fun.(args, state)
    {:ok, List.wrap(results), new_state}
  rescue
    e -> {:error, Exception.message(e), state}
  end

  defp do_call_function({:lua_closure, proto, upvalues}, args, state) do
    callee_regs = Tuple.duplicate(nil, max(proto.max_registers, proto.param_count) + 64)

    callee_regs =
      args
      |> Enum.with_index()
      |> Enum.reduce(callee_regs, fn {arg, i}, regs ->
        if i < proto.param_count, do: put_elem(regs, i, arg), else: regs
      end)

    {results, _regs, new_state} =
      Lua.VM.Executor.execute(proto.instructions, callee_regs, upvalues, proto, state)

    {:ok, results, new_state}
  rescue
    e -> {:error, Exception.message(e), state}
  end

  defp do_call_function(other, _args, state) do
    {:error, "undefined function '#{inspect(other)}'", state}
  end

  @doc """
  The raising variant of `call_function/3`

  This is also useful for executing Lua function's inside of Elixir APIs

  ```elixir
  defmodule MyAPI do
    use Lua.API, scope: "example"

    # TODO: Restore once string stdlib is implemented
    # deflua foo(value), state do
    #   Lua.call_function!(state, [:string, :lower], [value])
    # end
    deflua foo(value), state do
      Lua.call_function!(state, [:my_func], [value])
    end
  end
  ```
  """
  def call_function!(%__MODULE__{} = lua, func, args) do
    case call_function(lua, func, args) do
      {:ok, ret, lua} -> {ret, lua}
      {:error, reason, lua} -> raise Lua.RuntimeException, {:lua_error, reason, lua.state}
    end
  end

  @doc """
  Encodes a Lua value into its internal form

      <!-- Old Luerl implementation returned specific tref IDs: {encoded, _} = Lua.encode!(Lua.new(), %{a: 1}); encoded => {:tref, 14} -->

      iex> {encoded, _} = Lua.encode!(Lua.new(), %{a: 1})
      iex> match?({:tref, _}, encoded)
      true
  """
  def encode!(%__MODULE__{} = lua, value) when is_atom(value) and not is_boolean(value) do
    {Atom.to_string(value), lua}
  end

  def encode!(%__MODULE__{state: state} = lua, value) do
    {encoded, state} = Value.encode(value, state)
    {encoded, %{lua | state: state}}
  rescue
    _e in [ArgumentError] ->
      reraise Lua.RuntimeException, "Failed to encode #{inspect(value)}", __STACKTRACE__

    _e in [FunctionClauseError] ->
      reraise Lua.RuntimeException, "Failed to encode #{inspect(value)}", __STACKTRACE__
  end

  @doc """
  Encodes a list of values into a list of encoded value

  Useful for encoding lists of return values

      iex> {[1, {:tref, _}, true], _} = Lua.encode_list!(Lua.new(), [1, %{a: 2}, true])
  """
  def encode_list!(%__MODULE__{} = lua, list) when is_list(list) do
    Enum.map_reduce(list, lua, &encode!(&2, &1))
  end

  @doc """
  Decodes a Lua value from its internal form

      iex> {encoded, lua} = Lua.encode!(Lua.new(), %{a: 1})
      iex> Lua.decode!(lua, encoded)
      [{"a", 1}]

  """
  def decode!(%__MODULE__{state: state}, value) do
    if not Util.encoded?(value) do
      raise Lua.RuntimeException, "Failed to decode #{inspect(value)}"
    end

    Value.decode(value, state)
  rescue
    _e in [ArgumentError, KeyError] ->
      reraise Lua.RuntimeException, "Failed to decode #{inspect(value)}", __STACKTRACE__
  end

  @doc """
  Decodes a list of encoded values

  Useful for decoding all function arguments in a `deflua`

      iex> {encoded, lua} = Lua.encode_list!(Lua.new(), [1, %{a: 2}, true])
      iex> Lua.decode_list!(lua, encoded)
      [1, [{"a", 2}], true]
  """
  def decode_list!(%__MODULE__{} = lua, list) when is_list(list) do
    Enum.map(list, &decode!(lua, &1))
  end

  @doc """
  Loads a Lua file into the environment. Any values returned in the global
  scope are thrown away.

  Mimics the functionality of Lua's [dofile](https://www.lua.org/manual/5.4/manual.html#pdf-dofile)
  """
  def load_file!(%__MODULE__{} = lua, path) when is_binary(path) do
    # Add .lua extension if not present
    full_path =
      if String.ends_with?(path, ".lua") do
        path
      else
        path <> ".lua"
      end

    case File.read(full_path) do
      {:ok, content} ->
        {_results, lua} = eval!(lua, content)
        lua

      {:error, :enoent} ->
        raise "Cannot load lua file, #{inspect(full_path)} does not exist"

      {:error, reason} ->
        raise "Cannot load lua file #{inspect(full_path)}: #{reason}"
    end
  end

  @doc """
  Inject functions written with the `deflua` macro into the Lua runtime.

  See `Lua.API` for more information on writing api modules

  ### Options
  * `:scope` - (optional) scope, overriding whatever is provided in `use Lua.API, scope: ...`
  * `:data` - (optional) - data to be passed to the Lua.API.install/3 callback

  """
  def load_api(lua, module, opts \\ []) do
    opts = Keyword.validate!(opts, [:scope, :data])
    funcs = :functions |> module.__info__() |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    scope = opts[:scope] || module.scope()

    lua = ensure_scope!(lua, scope)

    lua =
      module.__lua_functions__()
      |> Enum.reduce(lua, fn {name, with_state?, variadic?}, lua ->
        arities = Map.get(funcs, name)

        func =
          if variadic? do
            wrap_variadic_function(module, name, with_state?)
          else
            wrap_function(module, name, arities, with_state?)
          end

        set!(lua, List.wrap(scope) ++ [name], func)
      end)

    Lua.API.install(lua, module, scope, opts[:data])
  end

  @doc """
  Puts a private value in storage for use in Elixir functions

      iex> Lua.new() |> Lua.put_private(:api_key, "1234")
  """
  def put_private(%__MODULE__{state: state} = lua, key, value) do
    %{lua | state: State.put_private(state, key, value)}
  end

  @doc """
  Gets a private value in storage for use in Elixir functions

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> Lua.get_private(lua, :api_key)
      {:ok, "1234"}
  """
  def get_private(%__MODULE__{state: state}, key) do
    {:ok, State.get_private(state, key)}
  rescue
    KeyError -> :error
  end

  @doc """
  Gets a private value in storage for use in Elixir functions, raises if the key doesn't exist

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> Lua.get_private!(lua, :api_key)
      "1234"
  """
  def get_private!(%__MODULE__{} = lua, key) do
    case get_private(lua, key) do
      {:ok, value} -> value
      :error -> raise "private key `#{inspect(key)}` does not exist"
    end
  end

  @doc """
  Deletes a key from private storage

      iex> lua = Lua.new() |> Lua.put_private(:api_key, "1234")
      iex> lua = Lua.delete_private(lua, :api_key)
      iex> Lua.get_private(lua, :api_key)
      :error
  """
  def delete_private(%__MODULE__{state: state} = lua, key) do
    %{lua | state: State.delete_private(state, key)}
  end

  # Note: These functions are called from load_api and always go through set!/3's
  # arity-2 clause, which wraps the state as %Lua{} before calling. So `lua` is
  # already a %Lua{} struct — do NOT call wrap() again.
  defp wrap_variadic_function(module, function_name, with_state?) do
    if with_state? do
      fn args, lua ->
        execute_function(module, function_name, [args, lua], lua)
      end
    else
      fn args, lua ->
        execute_function(module, function_name, [args], lua)
      end
    end
  end

  # credo:disable-for-lines:25
  defp wrap_function(module, function_name, arities, with_state?) do
    if with_state? do
      fn args, lua ->
        if (length(args) + 1) in arities do
          execute_function(module, function_name, args ++ [lua], lua)
        else
          arities = Enum.map(arities, &(&1 - 1))

          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    else
      fn args, lua ->
        if length(args) in arities do
          execute_function(module, function_name, args, lua)
        else
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "expected #{Enum.join(arities, " or ")} arguments, got #{length(args)}"
        end
      end
    end
  end

  defp execute_function(module, function_name, args, lua) do
    case apply(module, function_name, args) do
      # Table-like keyword list
      [{_, _} | _rest] ->
        raise Lua.RuntimeException,
          function: function_name,
          scope: module.scope(),
          message: "keyword lists must be explicitly encoded to tables using Lua.encode!/2"

      # Map
      map when is_map(map) ->
        raise Lua.RuntimeException,
          function: function_name,
          scope: module.scope(),
          message: "maps must be explicitly encoded to tables using Lua.encode!/2"

      {:error, reason} ->
        raise Lua.VM.RuntimeError, value: reason

      {:error, reason, %Lua{}} ->
        raise Lua.VM.RuntimeError, value: reason

      {data, %Lua{} = returned_lua} ->
        data = List.wrap(data)

        if not Util.list_encoded?(data) do
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "deflua functions must return encoded data, got #{inspect(data)}"
        end

        {data, returned_lua}

      data ->
        data = List.wrap(data)

        if not Util.list_encoded?(data) do
          raise Lua.RuntimeException,
            function: function_name,
            scope: module.scope(),
            message: "deflua functions must return encoded data, got #{inspect(data)}"
        end

        {data, lua}
    end
  catch
    thrown_value ->
      {:error,
       "Value thrown during function '#{function_name}' execution: #{inspect(thrown_value)}"}
  end

  defp ensure_scope!(lua, []) do
    lua
  end

  defp ensure_scope!(lua, scope) do
    set!(lua, scope, %{})
  end

  defp wrap(state), do: %__MODULE__{state: state}

  defp to_lua_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_lua_key(key) when is_binary(key), do: key
  defp to_lua_key(key), do: key
end
