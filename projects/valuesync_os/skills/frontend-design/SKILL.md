---
name: frontend-design
description: Design and implement polished, production-ready frontend UI for the ValuesyncOS CRM. Use when asked to create, restyle, or improve pages, components, layouts, or visual polish — within our existing design system (shadcn/ui, Tailwind, CSS variables).
compatibility: "Next.js 16, shadcn/ui (new-york), Tailwind CSS 4, Phosphor Icons"
---

# Frontend Design Skill

Design and implement high-quality frontend interfaces for ValuesyncOS — an M&A deal pipeline CRM built with Next.js 16, shadcn/ui, Tailwind CSS, and Supabase.

## Design Reference

The canonical design system is a live page with rendered examples, token tables, and behavioral specs:

**`app/internal/design-guidelines/page.tsx`**

Section files in `app/internal/design-guidelines/sections/`:

| File | Covers |
|------|--------|
| `PaletteSection.tsx` | Identity palette, navy/gold scales, semantic colors, delta indicators, borders & shadows |
| `ButtonSection.tsx` | Button variants, sizes, states |
| `BadgeSection.tsx` | Priority, pipeline, status, industry, user, document badge classes |
| `TypographySection.tsx` | Font stack (Inter / Roboto Mono), type scale, text hierarchy |
| `ChartSection.tsx` | KPI cards, chart color tokens, series swatches |
| `LayoutSection.tsx` | Shell architecture, grid system, border radius, heading hierarchy, spacing |
| `ComponentsSection.tsx` | Iconography (Phosphor), data tables, form elements, empty states |
| `TechSection.tsx` | Accessibility (WCAG AA), motion/animation timing, toasts/callouts, ARIA rules, core token reference |

**Before coding any UI**, read the section(s) relevant to your task. These files contain the resolved token values, component specs, and behavioral rules that `globals.css` implements.

## Startup Mindset

- **Leverage what exists** — shadcn/ui, Radix, Tailwind, CSS variables in `globals.css`. Don't reinvent.
- **Ship working UI** — a polished component today beats a perfect abstraction next week.
- **Copy before create** — check `components/ui/` before building anything new.
- **Skip diminishing returns** — custom animations, pixel-level micro-interactions, and exotic layouts rarely move the needle.

## Workflow

1. Read the design-guidelines section(s) relevant to your task
2. Read the existing page or component to understand current patterns
3. Check `components/ui/` for reusable primitives — use before creating new ones
4. Check `globals.css` for semantic badge classes and CSS variables
5. Implement using Server Components by default; `"use client"` only when needed
6. Verify both light and dark mode render correctly
7. Run the quality checklist before delivering

## Design System Constraints

Work **within** the established system. The design guidelines page is the source of truth for token values and component specs. Key rules:

### Colors

Use CSS variables from `globals.css` — never hardcode hex values. Both light and dark mode are defined. Semantic badge classes exist for priorities, stages, industries, statuses, etc. (e.g. `badge-priority-high`, `badge-stage-3`). Check `globals.css` for the full set.

### Typography

Inter (sans) and Roboto Mono (mono), loaded via `next/font/google`. Use Tailwind's type scale (`text-sm`, `text-base`, `text-lg`, etc.). Keep hierarchy simple: one prominent heading, supporting text in `text-muted-foreground`, data in default foreground.

### Spacing & Layout

Tailwind spacing utilities (`gap-4`, `p-6`, `space-y-3`). Cards: `rounded-lg border bg-card p-6`. Radius: `var(--radius)` = `0.5rem`. Responsive: mobile-first with `sm:`, `md:`, `lg:` breakpoints.

### Components

Use shadcn/ui from `components/ui/`. Check `ComponentsSection.tsx` in the design guidelines for the full inventory. Key primitives: `Button`, `Card`, `Dialog`, `Table`, `Input`, `Badge`, `DropdownMenu`, `Tabs`, `NavigationBar`, `Empty`, `EntityCombobox`, `Tooltip`.

### Icons

Phosphor Icons from `@phosphor-icons/react` (v2, `Icon` suffix). Default weight: `regular`. Sizes: `size={16}` inline, `size={20}` buttons, `size={32}+` empty states.

## Code Quality

- TypeScript strict — no `any`, explicit return types on exports
- Omit semicolons (ASI style)
- `@/` path alias for all imports
- Server Components by default, `"use client"` only when needed
- Data fetching via TanStack Query hooks from `lib/hooks/`

## What to Avoid

- Custom CSS files — use Tailwind utilities and `globals.css` variables
- New color tokens — work within the existing palette
- Over-componentization — don't extract until used in 2+ places
- Complex animations — subtle transitions are fine; check `TechSection.tsx` for timing specs
- Hardcoded colors — always use CSS variables
- Ignoring dark mode — every element must work in both themes

## Quality Checklist

- [ ] Uses shadcn/ui components — no redundant custom primitives
- [ ] Colors from CSS variables — works in light and dark mode
- [ ] Typography hierarchy is clear (one heading level, muted supporting text)
- [ ] Spacing consistent with rest of app
- [ ] Responsive — correct on mobile and desktop
- [ ] Interactive states present (hover, focus, disabled, loading)
- [ ] Empty states handled
- [ ] No `any` types, no hardcoded colors, no semicolons
- [ ] `pnpm build` passes
