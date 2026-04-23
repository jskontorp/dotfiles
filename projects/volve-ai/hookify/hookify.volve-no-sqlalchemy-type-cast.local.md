---
name: volve-no-sqlalchemy-type-cast
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: /app/.*\.py$
  - field: new_text
    operator: regex_match
    pattern: text\([^)]*::[a-z]
---

**SQLAlchemy `::type` cast inside `text()` — use `CAST(:param AS type)`**

volve-ai footgun: `::type` casts break with named bind parameters in `sqlalchemy.text()`. The `::` is parsed as a second `:param` reference, causing a runtime syntax error.

```python
# WRONG — will break at runtime
text("INSERT ... VALUES (:data::jsonb)")
text("SELECT unnest(:ids::text[])")

# CORRECT
text("INSERT ... VALUES (CAST(:data AS jsonb))")
text("SELECT unnest(CAST(:ids AS text[]))")
```

See `CLAUDE.md` section "CRITICAL — SQLAlchemy `text()` and PostgreSQL type casts".
