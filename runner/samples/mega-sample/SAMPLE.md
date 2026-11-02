# Mega sample — exercises every mirroir-run primitive end-to-end

This sample's SAMPLE.md drives:
- session-scoped boot (python http.server lives across scenarios)
- process target (spawn/wait_port/assert_log)
- http target (REST probe)
- web target via Playwright across chromium + firefox + webkit
- judge oracle (real Ollama LLM scoring)
- drift detection (response Levenshtein vs. captured baseline)
- cross-surface invariants (web capture ↔ iOS capture equivalence)

```yaml
version: 1
name: mega-sample
description: |
  Boot a python http.server once; multiple scenarios share it.
session:
  boot_once: true
  boot_ready_port: 18898
  boot_ready_timeout_s: 10
  boot:
    command: "python3 -c \"import http.server as h, socketserver as s; h.ThreadingHTTPServer.server_bind = s.TCPServer.server_bind; h.ThreadingHTTPServer(('127.0.0.1', 18898), h.SimpleHTTPRequestHandler).serve_forever()\""
  scenarios:
    must_pass:
      - scenarios/web-cross-browser.yaml
      - scenarios/web-locator-engines.yaml
      - scenarios/http-probe.yaml
      - scenarios/judge-and-drift.yaml
      - scenarios/cross-surface.yaml
```
