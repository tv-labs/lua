# Lua

<!-- MDOC !-->

`Lua` is an ergonomic interface to [Luerl](https://github.com/rvirding/luerl), aiming to be the best way to use Luerl from Elixir.

## Features

* Ergonomic API for Elixir <> Lua FFI
* Improved error messages
* Deep-setting variables and state
* Excellent documentation and guides for working with Luerl

> #### Lua the Elixir library vs Lua the language {: .info}
> When referring to this library, `Lua` will be stylized as a link.
> 
> References to Lua the language will be in plaintext and not linked.

## Executing Lua

`Lua` can be run using the `eval!/2` function

``` elixir
    iex> {[4], _} =
    ...>   Lua.eval!("""
    ...>   return 2 + 2
    ...>   """)

```

## Exposing Elixir functions to Lua

`Lua` provides the `deflua` macro for exposing Elixir functions to Lua

``` elixir
defmodule MyAPI do
  use Lua.API
      
  deflua double(v), do: 2 * v
end
    
lua = Lua.new() |> Lua.load_api(MyAPI)

{[10], _} =
  Lua.eval!(lua, """
  return double(5)
  """)

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

lua = Lua.new() |> Lua.load_api(MyAPI)

{["wow"], _} = Lua.eval!(lua, "return example.foo(\"WOW\")")
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
