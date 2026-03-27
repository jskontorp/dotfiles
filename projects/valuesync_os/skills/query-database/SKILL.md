---
name: query-database
version: 2.0.0
description: Query and explore the Supabase database directly from chat. Use when the user asks about database data, table structure, users, organizations, deals, contacts, directors, or any data exploration tasks.
---

# Query Database

Run Supabase queries directly from chat for data exploration and debugging.

## Constraints

- **READ-ONLY by default.** Never run `.insert()`, `.update()`, `.delete()`, or `.upsert()` unless the user explicitly requests a mutation.
- Never drop or truncate tables.
- Always add `.limit()` to prevent overwhelming output.
- Use the service role client (bypasses RLS) for exploration.

## Query Template

Use the helper at `.pi/skills/query-database/run-query.mjs`:

```bash
node --input-type=module --env-file=.env.local -e "
import { supabase } from './.pi/skills/query-database/run-query.mjs'
const { data, error } = await supabase
  .from('TABLE_NAME')
  .select('*')
  .limit(10)
if (error) console.error('Error:', error.message)
else console.log(JSON.stringify(data, null, 2))
"
```

### Explore Table Structure

```bash
node --input-type=module --env-file=.env.local -e "
import { supabase } from './.pi/skills/query-database/run-query.mjs'
const { data, error } = await supabase.from('TABLE_NAME').select('*').limit(1)
if (error) { console.error(error.message) }
else if (data?.[0]) {
  for (const [k, v] of Object.entries(data[0])) {
    const t = v === null ? 'null' : Array.isArray(v) ? 'array' : typeof v === 'object' ? 'object' : typeof v
    console.log(k + ': ' + t + ' = ' + JSON.stringify(v))
  }
} else { console.log('Table empty') }
"
```

### Auth Users

```bash
node --input-type=module --env-file=.env.local -e "
import { supabase } from './.pi/skills/query-database/run-query.mjs'
const { data } = await supabase.auth.admin.listUsers()
console.log(JSON.stringify(data.users.map(u => ({ id: u.id, email: u.email, created_at: u.created_at })), null, 2))
"
```

## Database Schema

All tables use `org_id` for multi-tenant RLS scoping.

### Core Tables

| Table | Key Columns | Notes |
|---|---|---|
| `organizations` | id, name, slug, settings (JSONB) | Multi-tenant root |
| `user_profiles` | id (= auth.users.id), full_name, email, current_org_id | 1:1 with auth.users |
| `user_org_memberships` | user_id, org_id, role (owner/admin/member/viewer), is_active | Many-to-many |
| `organization_invites` | org_id, email, role, token, expires_at, accepted_at | Pending invites |

### Deal Pipeline

| Table | Key Columns | Notes |
|---|---|---|
| `deals` | id, deal_name, current_stage_id, estimated_value, priority, org_id | Main deal entity |
| `pipeline_stages` | id, stage_key, stage_label, display_order, color, org_id | Configurable per org |
| `deal_stage_history` | deal_id, from_stage_id, to_stage_id, moved_at | Audit trail |
| `deal_perimeter` | deal_id, company_id, scope_type, ownership_target_pct | Deal-company scope |
| `deal_contacts` | deal_id, contact_id, role_in_deal, is_primary_contact | Deal participants |

### Companies & Contacts

| Table | Key Columns | Notes |
|---|---|---|
| `target_companies` | id, name, registration_number, industry_sector, country, metadata (JSONB), org_id | Central company store |
| `contacts` | id, full_name, title, email, phone, target_company_id, org_id | People |
| `contact_company_associations` | contact_id, company_id, role_type, is_current | Many-to-many |

### Activities & Chat

| Table | Key Columns | Notes |
|---|---|---|
| `activities` | id, type_id, author_id, subject, description, occurred_at, is_completed, org_id | Interactions |
| `rel_activity_contact` | activity_id, contact_id, org_id | Activity ↔ contact (many-to-many) |
| `rel_activity_company` | activity_id, company_id, org_id | Activity ↔ company (many-to-many) |
| `rel_activity_deal` | activity_id, deal_id, org_id | Activity ↔ deal (many-to-many) |
| `chat_conversations` | id, title, user_id, context_type, context_entity_id, org_id | AI chat sessions |
| `chat_messages` | conversation_id, role, content, tool_invocations (JSONB), org_id | Chat history |

### AI & Workflows

| Table | Key Columns | Notes |
|---|---|---|
| `ai_workflows` | id, deal_id, workflow_type, status, data (JSONB), org_id | Research results |
| `ai_artifacts` | id, title, kind (text/sheet/code), content, status (draft/published), org_id | AI-generated docs |
| `rel_artifact_entity` | artifact_id, entity_type, entity_id | Polymorphic links |

### Creditsafe (External Data)

| Table | Key Columns | Notes |
|---|---|---|
| `creditsafe_company` | id, csafe_number, org_number, name, country, latest_turnover_value, org_id | Enriched company data |
| `creditsafe_director` | id, creditsafe_company_id, name, position_name, date_appointed, current_directorships | Directors |
| `creditsafe_financial_statement` | creditsafe_company_id, year, type, currency | Financials |
| `creditsafe_shareholder` | creditsafe_company_id, name, share_percent | Ownership |

Other Creditsafe tables: `creditsafe_rating_history`, `creditsafe_commentary`, `creditsafe_pledge`, `creditsafe_branch_office`, `creditsafe_corporate_event`, `creditsafe_auditor_comment`.

## Common Joins

```javascript
// Deal with stage label
supabase.from('deals')
  .select('*, pipeline_stages(stage_label, color)')
  .limit(10)

// Deal perimeter — which companies are in a deal
supabase.from('deal_perimeter')
  .select('*, deals(deal_name), target_companies(name, country)')
  .limit(10)

// Director with company
supabase.from('creditsafe_director')
  .select('name, position_name, creditsafe_company(name, org_number)')
  .limit(10)

// Contact with company associations
supabase.from('contact_company_associations')
  .select('*, contacts(full_name, email), target_companies(name)')
  .eq('is_current', true)
  .limit(10)
```

## Application Code Patterns

When writing app code (not ad-hoc queries):

```typescript
// Client-side
import { createClient } from "@/lib/supabase/client"
const supabase = createClient()

// Server-side (RSC, API routes)
import { createClient } from "@/lib/supabase/server"
const supabase = await createClient()

// Admin / bypass RLS
import { createServiceRoleClient } from "@/lib/supabase/server"
const supabase = createServiceRoleClient()
```

## Troubleshooting

| Error | Fix |
|---|---|
| "Could not find table in schema cache" | Check table name — try singular/plural variations |
| `null` results | Table may be empty, or RLS is blocking — use service role key |
| Connection error | Verify `.env.local` has `NEXT_PUBLIC_SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` |
