# Error formatter output is gated on IO.ANSI.enabled?/0, which returns true
# when stdout is a real TTY. Force it off so golden-snapshot tests are
# deterministic regardless of how the suite is launched. Tests that need
# ANSI on flip it locally and restore it via on_exit/1 (see
# test/lua/call_function_error_value_test.exs).
Application.put_env(:elixir, :ansi_enabled, false)

# `:differential` tests shell out to a reference `luac` and compare exact
# line numbers; they are environment-dependent (luac version / availability)
# and opt-in. Run them with `mix test --include differential`.
#
# `:lua53` runs the Lua 5.3 official suite — slow and noisy (the suite files
# print() heavily). It is opt-in: `mix test --include lua53` (or `--only`).
ExUnit.start(exclude: [:slow, :differential, :lua53])
