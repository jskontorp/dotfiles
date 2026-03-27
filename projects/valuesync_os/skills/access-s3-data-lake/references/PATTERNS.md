# S3 Data Lake — Reference Patterns

Detailed code patterns for working with the Supabase S3 data lake.
All examples use the helper at `run-s3.mjs` in this skill directory.

## Creditsafe File Naming Convention

```
creditsafe/{country}-{type}-{creditsafe_id}--{company_slug}/{date}_{company_slug}_raw.json
```

**Example:**
```
creditsafe/DK-X-DK02992126--simcorp_a_s/20251022_simcorp_a_s_raw.json
```

### Parse File Paths

```javascript
function parseFilePath(key) {
  // Example: creditsafe/DK-X-DK02992126--simcorp_a_s/20251022_simcorp_a_s_raw.json
  const parts = key.split("/")
  const folder = parts[1] // DK-X-DK02992126--simcorp_a_s
  const filename = parts[2] // 20251022_simcorp_a_s_raw.json

  const [countryType, companySlug] = folder.split("--")
  const [country, type, creditsafeId] = countryType.split("-")

  const dateMatch = filename.match(/^(\d{8})/)
  const date = dateMatch ? dateMatch[1] : null

  return { country, type, creditsafeId, companySlug, date, filename }
}
```

## AI Workflow File Naming Convention

```
ai_workflows/{workflow_type}/{country}-{org_number}--{company_slug}/{timestamp}_{company_slug}_raw.json
```

**Example:**
```
ai_workflows/competitor_intelligence/DK-DK02992126--simcorp_a_s/20260129_143025_simcorp_a_s_raw.json
```

## Filtering Patterns

### By Company Name

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll('creditsafe/')
const matches = files.filter(f => f.Key?.includes('simcorp'))
console.log(matches.map(f => f.Key))
"
```

### By Country

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll('creditsafe/')
const dk = files.filter(f => f.Key?.startsWith('creditsafe/DK-'))
const de = files.filter(f => f.Key?.startsWith('creditsafe/DE-'))
console.log('DK:', dk.length, 'DE:', de.length)
"
```

### Get Latest File for a Company

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll, getJson } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll('creditsafe/')
const latest = files
  .filter(f => f.Key?.includes('simcorp_a_s'))
  .sort((a, b) => (b.LastModified?.getTime() || 0) - (a.LastModified?.getTime() || 0))[0]
if (latest) {
  console.log('Key:', latest.Key)
  const data = await getJson(latest.Key)
  console.log(JSON.stringify(data, null, 2).slice(0, 2000))
}
"
```

### Analyze File Types and Sizes

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll()
const byType = {}
let totalSize = 0
for (const f of files) {
  const ext = f.Key?.split('.').pop()?.toLowerCase() || 'unknown'
  byType[ext] = (byType[ext] || 0) + 1
  totalSize += f.Size || 0
}
console.log('Total files:', files.length)
console.log('Total size:', (totalSize / 1024 / 1024).toFixed(2), 'MB')
console.log('By type:', byType)
"
```

## Custom Explorer Template

For more complex analysis, create a standalone script:

```javascript
import { listAll, getJson } from './.pi/skills/access-s3-data-lake/run-s3.mjs'

async function analyzeCompany(companySlug) {
  const files = await listAll('creditsafe/')
  const companyFiles = files
    .filter(f => f.Key?.includes(companySlug))
    .sort((a, b) => (b.LastModified?.getTime() || 0) - (a.LastModified?.getTime() || 0))

  console.log(`Found ${companyFiles.length} files for ${companySlug}`)

  if (companyFiles.length > 0) {
    const data = await getJson(companyFiles[0].Key)
    return { file: companyFiles[0], data }
  }
}

analyzeCompany('simcorp_a_s').then(r => console.log(JSON.stringify(r, null, 2)))
```

## Error Handling

| Error | Cause | Fix |
|---|---|---|
| `S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY are required` | Missing credentials | Add to `.env.local` |
| `Could not extract project ref` | Malformed `NEXT_PUBLIC_SUPABASE_URL` | Check URL format: `https://{ref}.supabase.co` |
| `NoSuchKey` | File path doesn't exist | List files first to verify the key |
| `AccessDenied` | Wrong credentials or bucket permissions | Verify S3 keys in Supabase dashboard |

## Application Code Integration

In the Next.js app, use the existing singleton client instead of raw S3:

```typescript
// Server-side — use the app's S3 client
import { getS3Client, DATA_LAKE_BUCKET } from "@/lib/storage/s3-client"

// Workflow storage — use the dedicated helper
import { storeWorkflowResponse } from "@/lib/storage/workflow-storage"
```

Key files:
- `lib/storage/s3-client.ts` — Singleton S3 client with `getS3Client()` and `DATA_LAKE_BUCKET`
- `lib/storage/workflow-storage.ts` — `storeWorkflowResponse()` for AI workflow results

## Package Requirements

Already installed in this project (`@aws-sdk/client-s3`). For new projects:
```bash
pnpm add @aws-sdk/client-s3
```
