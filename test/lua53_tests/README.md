# Lua 5.3 Test Suite

This directory contains tests from the official Lua 5.3 test suite, used to verify compatibility with the Lua language specification.

## Downloading the Test Suite

The test files are not checked into git. To download them:

```bash
mix lua.get_tests
```

This will download and extract the Lua 5.3.4 test suite from https://www.lua.org/tests/

## License

The Lua test suite is distributed under the MIT License.

**Copyright © 1994–2025 Lua.org, PUC-Rio**

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

For more information, see: https://www.lua.org/license.html

## Custom Tests

Files that are checked into git:
- `simple_test.lua` - Basic infrastructure test to verify test harness works
