---
name: access-s3-data-lake
description: Access and analyze company credit data stored in the Supabase S3 data lake. Use when working with Creditsafe data, raw JSON files, company research data, or when the user mentions S3, data lake, or storage buckets.
metadata:
  version: "1.0"
---

# Access S3 Data Lake

Access and analyze company data from the Supabase S3 bucket named `lake`.

## Constraints

- **READ-ONLY by default.** Do not upload, overwrite, rename, or delete objects unless the user explicitly requests it.
- When mutating, confirm the target key with the user before executing.
- Always paginate when listing (the helper handles this automatically).
- Limit JSON output to avoid flooding the console — use `.slice()` or cherry-pick fields.

## Data Lake Structure

```
lake/
├── creditsafe/
│   └── {country}-{type}-{creditsafe_id}--{company_slug}/
│       └── {date}_{company_slug}_raw.json
└── ai_workflows/
    └── {workflow_type}/{country}-{org_number}--{company_slug}/
        └── {timestamp}_{company_slug}_raw.json
```

**Example:** `creditsafe/DK-X-DK02992126--simcorp_a_s/20251022_simcorp_a_s_raw.json`

## Quick Start

Use the helper at `.pi/skills/access-s3-data-lake/run-s3.mjs`. It exports `listAll(prefix?)`, `getJson(key)`, and the raw `s3` client.

### List All Files

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll('creditsafe/')
console.log('Total:', files.length)
for (const f of files.slice(0, 20)) console.log(f.Key, f.Size)
"
```

### Download a File

```bash
node --input-type=module --env-file=.env.local -e "
import { getJson } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const data = await getJson('creditsafe/DK-X-DK02992126--simcorp_a_s/20251022_simcorp_a_s_raw.json')
console.log(JSON.stringify(data, null, 2).slice(0, 3000))
"
```

### Search by Company Name

```bash
node --input-type=module --env-file=.env.local -e "
import { listAll } from './.pi/skills/access-s3-data-lake/run-s3.mjs'
const files = await listAll('creditsafe/')
const matches = files.filter(f => f.Key?.includes('simcorp'))
console.log(matches.map(f => ({ key: f.Key, size: f.Size, modified: f.LastModified })))
"
```

## Environment Variables

Required in `.env.local`:

```bash
S3_ACCESS_KEY_ID=your_access_key
S3_SECRET_ACCESS_KEY=your_secret_key
NEXT_PUBLIC_SUPABASE_URL=https://{project-ref}.supabase.co
```

## Application Code

In the Next.js app, use the existing singleton client — not raw S3 construction:

```typescript
import { getS3Client, DATA_LAKE_BUCKET } from "@/lib/storage/s3-client"
import { storeWorkflowResponse } from "@/lib/storage/workflow-storage"
```

Key files: `lib/storage/s3-client.ts`, `lib/storage/workflow-storage.ts`.

## More Patterns

See [references/PATTERNS.md](references/PATTERNS.md) for:
- File path parsing and naming conventions
- Filtering by country, company, and date
- File type/size analysis
- Custom explorer template
- Error handling reference
- Full package requirements

## Checklist

- [ ] Verify `.env.local` has `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, and `NEXT_PUBLIC_SUPABASE_URL`
- [ ] Use `run-s3.mjs` helper for ad-hoc queries
- [ ] Use `lib/storage/s3-client.ts` for application code
- [ ] Handle pagination for >1000 files (automatic with `listAll`)
- [ ] Never mutate bucket contents unless explicitly requested
