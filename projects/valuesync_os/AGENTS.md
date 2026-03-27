# valuesync_os — Project Agent Config

## Skill loading

Load skills when the plan touches their domain:

| Domain | Skill | Trigger |
|--------|-------|---------|
| UI / frontend | **frontend-design** | Plan includes new/modified pages, components, layouts, or visual changes. **Read the skill and the relevant design-guidelines sections before writing any UI code.** |
| Data / schema | **query-database** | Plan requires exploring DB structure or data |
| Notion specs | **read-notion** | Ticket links to a Notion page |
