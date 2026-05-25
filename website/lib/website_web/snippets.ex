defmodule DemoWeb.Snippets do
  @moduledoc """
  Source for the rotating code snippets shown on the marketing pages.

  Keeping them in a module (rather than inline in `.heex`) sidesteps
  heredoc-inside-heredoc escape headaches and makes the snippets
  unit-testable.
  """

  @hero [
    %{
      label: "rules.exs",
      source: """
      # Embed Lua in your Elixir app
      # with a single function call.

      defmodule MyApp.Rules do
        use Lua.API, scope: "rules"

        deflua double(n), do: n * 2
      end

      # Now your Elixir function is
      # callable from any Lua script:

      lua = Lua.new() |> Lua.load_api(MyApp.Rules)

      {[10], _lua} = Lua.eval!(lua, "return rules.double(5)")
      """
    },
    %{
      label: "sigil.exs",
      source: ~S'''
      # Compile Lua at compile-time with the
      # ~LUA sigil. `c` returns a compiled chunk,
      # ready to run on any state.

      import Lua, only: [sigil_LUA: 2]

      chunk = ~LUA"""
        local total = 0
        for i = 1, 100 do total = total + i end
        return total
      """c

      {[5050], _state} = Lua.run(Lua.new(), chunk)
      '''
    },
    %{
      label: "sandbox.exs",
      source: """
      # Sandboxed by default. No file system,
      # no os.execute, no surprise side-effects.

      lua = Lua.new()

      {:error, err} =
        Lua.eval(lua, "return os.execute('rm -rf /')")

      # err.message =~ "attempted to call"
      """
    },
    %{
      label: "agent.exs",
      source: """
      # Give an LLM a Lua VM with your tools
      # bound. It can only call what you expose.

      defmodule Agent.Tools do
        use Lua.API, scope: "tools"

        deflua search(q), do: MyApp.Search.run(q)
      end

      lua = Lua.new() |> Lua.load_api(Agent.Tools)

      # The model emits Lua. You run it. Done.
      {:ok, {results, _}} = Lua.eval(lua, llm_script)
      """
    }
  ]

  @embed [
    %{
      label: "queue.exs",
      source: """
      defmodule Queue do
        use Lua.API, scope: "q"

        deflua push(v), state do
          queue = Lua.get!(state, [:my_queue])

          {[], state} =
            Lua.call_function!(
              state,
              [:table, :insert],
              [queue, v]
            )

          {[], state}
        end
      end

      lua =
        Lua.new()
        |> Lua.load_api(Queue)
        |> Lua.set!([:my_queue], [])

      Lua.eval!(lua, \"\"\"
        q.push("hello")
        q.push("world")
      \"\"\")
      """
    },
    %{
      label: "formulas.exs",
      source: """
      # Let your users define formulas in Lua
      # that call back into your domain code.

      defmodule Pricing do
        use Lua.API, scope: "pricing"

        deflua discount(amount, pct) do
          amount * (1 - pct / 100)
        end
      end

      lua = Lua.new() |> Lua.load_api(Pricing)

      {[result], _} =
        Lua.eval!(lua, "return pricing.discount(100, 15)")
      """
    },
    %{
      label: "plugins.exs",
      source: """
      # Plug-in system: ship a Lua VM per tenant,
      # preload their script, and call into it.

      defmodule Tenant do
        def run(script, event) do
          Lua.new()
          |> Lua.set!([:event], event)
          |> Lua.eval!(script)
        end
      end

      script = ~S\"\"\"
        if event.amount > 1000 then
          return "review"
        else
          return "auto-approve"
        end
      \"\"\"

      {["review"], _} = Tenant.run(script, %{amount: 5_000})
      """
    }
  ]

  @agent_tool """
  defmodule MyAgent.Tools do
    use Lua.API, scope: "tools"

    deflua search(query), state do
      results = MyApp.Search.run(query)
      {[results], state}
    end

    deflua send_email(to, body), state do
      MyApp.Mailer.deliver(to, body)
      {[:ok], state}
    end
  end

  # One VM per agent conversation.
  lua = Lua.new() |> Lua.load_api(MyAgent.Tools)

  # The agent emits Lua. You run it. It can only
  # do what you exposed -- nothing else.
  {:ok, {result, _lua}} = Lua.eval(lua, agent_script)
  """

  def hero, do: @hero
  def embed, do: @embed
  def agent_tool, do: @agent_tool
end
