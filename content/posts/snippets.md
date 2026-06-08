---
title: "A few snippets I reach for"
date: 2026-06-08
description: "A handful of small patterns across shell, Python, Go, and TOML."
---

A grab bag of small things, kept here so the syntax highlighting has something
to chew on and so I stop re-deriving them.

A guard at the top of every shell script:

```bash
#!/usr/bin/env bash
set -euo pipefail

# bail early if a required tool is missing
if ! command -v jq >/dev/null; then
  echo "jq is required" >&2
  exit 1
fi
```

A tiny retry helper in Python:

```python
import time

def retry(fn, attempts=3, base=0.5):
    """Call fn, backing off on failure."""
    for n in range(attempts):
        try:
            return fn()
        except Exception as err:  # noqa: BLE001
            if n == attempts - 1:
                raise
            time.sleep(base * 2**n)
            print(f"retry {n + 1}: {err!r}")
```

A struct tag in Go is just a backtick string:

```go
package main

/* Config is loaded from the environment. */
type Config struct {
    Port  int    `env:"PORT"`
    Token string `env:"TOKEN"`
}

const defaultMask uint32 = 0xDEADBEEF
```

And the config it parses:

```toml
# service defaults
port = 8080
timeout = 1.5
name = "edge"
```
