# Lua

<!-- MDOC !-->

`Lua` is an ergonomic interface to [Luerl](https://github.com/rvirding/luerl), aiming to be the best way to use Luerl from Elixir.

## Features

* `~LUA` sigil for validating Lua code at compile-time
* `deflua` macro for exposing Elixir functions to Lua
* Improved error messages and sandboxing
* Deep setting/getting variables and state
* Excellent documentation and guides for working with Luerl

> #### Lua the Elixir library vs Lua the language {: .info}
> When referring to this library, `Lua` will be stylized as a link.
> 
> References to Lua the language will be in plaintext and not linked.

## Executing Lua

`Lua` can be run using the `eval!/2` function

    iex> {[4], _} = Lua.eval!("return 2 + 2")

## Compile-time validation

Use the `~LUA` sigil to parse and validate your Lua code at compile time

    iex> import Lua, only: [sigil_LUA: 2]

    #iex> {[4], _} = Lua.eval!(~LUA[return 2 +])
    ** (Lua.CompilerException) Failed to compile Lua!

Using the `c` modifier transforms your Lua code into a `t:Lua.Chunk.t/0` at compile-time,
which will speed up execution at runtime since the Lua no longer needs to be parsed

    iex> import Lua, only: [sigil_LUA: 2]
    iex> {[4], _} = Lua.eval!(~LUA[return 2 + 2]c)

## Exposing Elixir functions to Lua

The simplest way to expose an Elixir function to Lua is using the `Lua.set!/3` function

``` elixir
import Lua, only: [sigil_LUA: 2]

lua = 
  Lua.set!(Lua.new(), [:sum], fn args ->
    [Enum.sum(args)]
  end)

{[10], _} = Lua.eval!(lua, ~LUA[return sum(1, 2, 3, 4)]c)
```

For easily expressing APIs, `Lua` provides the `deflua` macro for exposing Elixir functions to Lua

``` elixir
defmodule MyAPI do
  use Lua.API
      
  deflua double(v), do: 2 * v
end

import Lua, only: [sigil_LUA: 2]
    
lua = Lua.new() |> Lua.load_api(MyAPI)

{[10], _} = Lua.eval!(lua, ~LUA[return double(5)])
```

## Calling Lua functions from Elixir

`Lua` can be used to expose complex functions written in Elixir. In some cases, you may want to call Lua functions from Elixir. This can
be achieved with the `Lua.call_function!/3` function

``` elixir
defmodule MyAPI do
  use Lua.API, scope: "example"

  deflua foo(value), state do
    Lua.call_function!(state, [:string, :lower], [value])
  end
end

import Lua, only: [sigil_LUA: 2]

lua = Lua.new() |> Lua.load_api(MyAPI)

{["wow"], _} = Lua.eval!(lua, ~LUA[return example.foo("WOW")])
```

## Modify Lua state from Elixir

You can also use `Lua` to modify the state of the lua environment inside your Elixir code. Imagine you have a queue module that you
want to implement in Elixir, with the queue stored in a global variable

``` elixir
defmodule Queue do
  use Lua.API, scope: "q"
  
  deflua push(v), state do
    # Pull out the global variable "my_queue" from lua
    queue = Lua.get!(state, [:my_queue])
    
    # Call the Lua function table.insert(table, value)
    {[], state} = Lua.call_function!(state, [:table, :insert], [queue, v])
    
    # Return the modified lua state with no return values
    {[], state}
  end
end

import Lua, only: [sigil_LUA: 2]

lua = Lua.new() |> Lua.load_api(Queue)

{[queue], _} =
  Lua.eval!(lua, """
  my_queue = {}

  q.push("first")
  q.push("second")

  return my_queue
  """)
  
["first", "second"] = Lua.Table.as_list(queue)
```

## Credits

`Lua` piggy-backs off of Robert Virding's [Luerl](https://github.com/rvirding/luerl) project, which implements a Lua lexer, parser, and full-blown Lua virtual machine that runs inside the BEAM.
