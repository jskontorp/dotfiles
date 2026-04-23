---
name: volve-no-print
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: /app/.*\.py$
  - field: new_text
    operator: regex_match
    pattern: \bprint\(
---

**`print()` in app code — use the structured logger**

volve-ai rule: never use `print()` for errors, debugging, or status messages.

```python
from app.utility.logging_config import get_logger
logger = get_logger(__name__)

logger.info("Processing document %s", doc_id)
logger.error("Failed: %s", e)
```

See `CLAUDE.md` section "6. Logging — No print()".
