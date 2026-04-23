---
name: volve-no-raise-valueerror-in-services
enabled: true
event: file
conditions:
  - field: file_path
    operator: regex_match
    pattern: /app/db/services/.*\.py$
  - field: new_text
    operator: regex_match
    pattern: raise\s+ValueError\(
---

**`raise ValueError` in a service — use HTTPException or return None**

volve-ai rule: services should NOT raise `ValueError` for domain errors. The global `ValueError` handler maps based on brittle string matching (`"not found"` → 404, else → 400).

Instead:
- Return `None` from the service; raise `HTTPException` at the endpoint level
- Or raise `HTTPException` directly when the error is HTTP-specific

```python
# In service
def get_document(self, doc_id: str) -> Optional[DocumentResponse]:
    doc = self.repo.get_by_doc_id(doc_id)
    if not doc:
        return None
    return self._build_response(doc)

# In endpoint
async def get_document(doc_id: str, service = Depends(get_svc)):
    result = await asyncio.to_thread(service.get_document, doc_id)
    if result is None:
        raise HTTPException(status_code=404, detail=f"Document {doc_id} not found")
    return result
```

See `CLAUDE.md` section "3. Error Handling — No `raise ValueError` in Services".
