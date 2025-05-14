# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.2.0] - 2025-05-14

### Changed
- Any data returned from a `deflua` function, or a function set by `Lua.set!/3` is now validated. If the data is not an identity value, or an encoded value, it will raise an exception. In the past, `Lua` and Luerl would happily accept bad values, causing downstream problem is the program. This led to unexpected behavior, where depending on if the data passed was decoded or not, the program would succeed or fail


## [v0.1.1] - 2025-05-13

### Added
- `Lua.put_private/3`, `Lua.get_private/2`, `Lua.get_private!/2`, and `Lua.delete_private/2` for working with private state

## [v0.1.0] - 2025-05-12

### Fixed

- Errors now correctly propagate state updates
- Fixed version requirements issues, causing references to undefined `luerl_new`
- Allow Unicode characters to be used in Lua scripts
- Files with only comments can be loaded

### Changed

- Upgrade to Luerl 1.4.1
- Tables must now be explicitly decoded when receiving as arguments `deflua` and other Elixir callbacks


[unreleased]: https://github.com/tv-labs/lua/compare/v0.2.0...HEAD
[0.1.1]: https://github.com/tv-labs/lua/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/tv-labs/lua/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tv-labs/lua/compare/v0.0.22...v0.1.0
