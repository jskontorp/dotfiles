---
name: volve-no-time-sleep
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: /app/.*\.py$
  - field: new_text
    operator: regex_match
    pattern: \btime\.sleep\(
---

**`time.sleep()` in app code — use `asyncio.sleep()`**

volve-ai is async-throughout. `time.sleep()` blocks the event loop.

```python
import asyncio
await asyncio.sleep(1)
```

For sync code that must stay sync, `time.sleep()` is fine — but almost all `app/` code is async, so double-check intent.

See `CLAUDE.md` section "4. Async Patterns — Never use blocking libraries in async functions".
