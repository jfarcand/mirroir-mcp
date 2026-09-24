# Third-Party Notices

This repository is licensed under the Apache License, Version 2.0 (see `LICENSE`).
It includes software derived from the third-party projects below, each under its own license.

## go-ios

- Project: https://github.com/danielpaulus/go-ios
- Used in: `Sources/MirroirCoreDevice/` (a Swift port of go-ios's RemoteXPC, HTTP/2, RSD,
  UniversalHID and display-service code) and `Tests/MirroirCoreDeviceTests/` (test vectors and
  fixtures derived from go-ios: `xpc_dict.bin`, `xpc_empty_dict.bin`, the RSD handshake data and
  the golden display-stream offer).
- License: MIT

```
MIT License

Copyright (c) 2019 danielpaulus

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ipb

- Project: https://github.com/ipbtools/ipb
- Used in: `Sources/MirroirCoreDevice/TouchscreenReport.swift` follows the DigitizerReport field
  layout documented in ipb's `docs/protocol.md`. No ipb source code is copied.
