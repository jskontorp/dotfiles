---
name: volve-no-inline-service
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: /app/api/.*endpoint.*\.py$
  - field: new_text
    operator: regex_match
    pattern: =\s*[A-Z]\w*Service\(\)
---

**Inline service instantiation in endpoint — use `Depends()`**

volve-ai rule: services MUST be injected via FastAPI's `Depends()` with a factory function, not instantiated inline in the endpoint body.

```python
# GOOD — factory + Depends()
def get_documents_service() -> DocumentsService:
    return DocumentsService()

@router.get("/documents")
async def list_documents(
    service: DocumentsService = Depends(get_documents_service),
):
    return await asyncio.to_thread(service.list_docs)

# BAD — inline
@router.get("/documents")
async def list_documents():
    service = DocumentsService()  # Don't do this
    return service.list_docs()
```

See `CLAUDE.md` section "2. Service Dependency Injection via `Depends()`".
