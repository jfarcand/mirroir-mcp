# Fixtures

| File | Source | License |
|---|---|---|
| `xpc_dict.bin`, `xpc_empty_dict.bin` | Copied from go-ios `ios/xpc/` | MIT, Copyright (c) 2019 danielpaulus (see `THIRD_PARTY_NOTICES.md`) |
| `rsd_handshake.json` | Built from go-ios `ios/rsd_test.go` handshake data; device identifiers (serial, UDID, ECID, MAC, UUIDs) replaced with synthetic values | MIT, Copyright (c) 2019 danielpaulus (see `THIRD_PARTY_NOTICES.md`) |
| `devicectl_connected.json`, `devicectl_unavailable.json` | `xcrun devicectl list devices --json-output` on a local Mac, with every device identifier replaced | Apache-2.0 (this repository) |
