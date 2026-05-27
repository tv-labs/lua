# Vendored luassert integration test

This directory contains vendored Lua source from two upstream libraries,
used as end-to-end regression coverage for the `require` pipeline.

## Pinned versions

| Library  | Tag     | Upstream                                                |
| -------- | ------- | ------------------------------------------------------- |
| luassert | v1.9.0  | https://github.com/lunarmodules/luassert/tree/v1.9.0    |
| say      | v1.4.1  | https://github.com/lunarmodules/say/tree/v1.4.1         |

## Why these libraries

luassert is the assertion library used by [busted](https://lunarmodules.github.io/busted/),
the dominant testing framework in the Lua ecosystem. It exercises:

- Multi-level `require` chains.
- Modules with 50+ top-level `local function` definitions that close
  over the module's own top-level locals.
- Modules that return tables and modules that only register side
  effects and return nothing.
- `setmetatable`, `__call`, `__index` metamethods on returned values.

`say` is luassert's i18n dependency. Both are pure Lua, no C bindings.

The shape of `luassert/assertions.lua` — `local assert = require('luassert.assert')`,
followed by many `local function` definitions, followed by
`assert:register(...)` — is what surfaced the bug fixed in
[#244](https://github.com/tv-labs/lua/issues/244).

## Layout

```
lua/
├── luassert/
│   ├── LICENSE                  ← upstream MIT license
│   ├── init.lua                 ← top-level entrypoint
│   ├── assert.lua               ← core obj/metatable
│   ├── assertions.lua           ← built-in assertions (the bug's epicenter)
│   ├── modifiers.lua
│   ├── array.lua
│   ├── spy.lua / stub.lua / mock.lua
│   ├── match.lua
│   ├── state.lua / util.lua / namespaces.lua / compatibility.lua
│   ├── formatters/
│   ├── matchers/
│   └── languages/
└── say/
    ├── LICENSE                  ← upstream MIT license
    └── init.lua                 ← i18n string lookup
```

The `lua/` prefix matches the conventional `package.path` of
`?.lua;?/init.lua`, so `require('luassert')` resolves to
`lua/luassert/init.lua` and `require('luassert.assert')` resolves to
`lua/luassert/assert.lua`.

## Updating the pin

```
# From repo root.
cd /tmp
rm -rf luassert-* say-*
curl -sL -o luassert.tar.gz \
  https://github.com/lunarmodules/luassert/archive/refs/tags/vX.Y.Z.tar.gz
curl -sL -o say.tar.gz \
  https://github.com/lunarmodules/say/archive/refs/tags/vA.B.C.tar.gz
tar -xzf luassert.tar.gz && tar -xzf say.tar.gz

cd <repo>/test/integration/luassert/lua
rm -rf luassert/ say/
mkdir -p luassert say
cp -r /tmp/luassert-X.Y.Z/src/* luassert/
cp -r /tmp/say-A.B.C/src/say/init.lua say/
cp /tmp/luassert-X.Y.Z/LICENSE luassert/LICENSE
cp /tmp/say-A.B.C/LICENSE say/LICENSE
```

Then update the version table above and re-run
`mix test test/integration/luassert_test.exs`.

## License

Both libraries are MIT-licensed. The upstream `LICENSE` files are
preserved alongside the vendored source.
