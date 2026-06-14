# `:differential` tests shell out to a reference `luac` and compare exact
# line numbers; they are environment-dependent (luac version / availability)
# and opt-in. Run them with `mix test --include differential`.
ExUnit.start(exclude: [:slow, :differential])
