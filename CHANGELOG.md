# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased


## [v0.4.0] - 2025-12-06

### Changed
- Upgrade to Luerl 1.5.1

### Fixed
- Warnings on Elixir 1.19

## [v0.3.0] - 2025-06-09

### Added
- Guards for encoded Lua values in `deflua` functions
  - `is_table/1`
  - `is_userdata/1`
  - `is_lua_func/1`
  - `is_erl_func/1`
  - `is_mfa/1`

### Fixed
- `deflua` function can now specify guards when using or not using state

## [v0.2.1] - 2025-05-14

### Added
- `Lua.encode_list!/2` and `Lua.decode_list!/2` for encoding and decoding function arguments and return values

### Fixed
- Ensure that list return values are properly encoded

## [v0.2.0] - 2025-05-14

### Changed
- Any data returned from a `deflua` function, or a function set by `Lua.set!/3` is now validated. If the data is not an identity value, or an encoded value, it will raise an exception. In the past, `Lua` and Luerl would happily accept bad values, causing downstream problems in the program. This led to unexpected behavior, where depending on if the data passed was decoded or not, the program would succeed or fail.


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

[unreleased]: https://github.com/tv-labs/lua/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/tv-labs/lua/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/tv-labs/lua/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/tv-labs/lua/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/tv-labs/lua/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/tv-labs/lua/compare/v0.0.22...v0.1.0
