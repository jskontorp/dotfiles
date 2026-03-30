# Pi Agent Skills — Wishlist

Prioritized list of skills to add, based on tech stacks across `~/code/`.

> Last reviewed: 2025-03-25

## Tech landscape

| Project | Role | Stack |
|---|---|---|
| **valuesync_os** | Work — product | Next.js, Supabase, Tailwind, AI SDK, Radix, Vitest, Stryker |
| **nexus** | Work — product | FastAPI + SQLAlchemy + Pydantic AI (backend), Next.js + Radix + AI SDK + Playwright (frontend) |
| **docu-chat-jskontorp** | Personal — AI chat | Next.js, AI SDK, Langfuse, Rive |
| **micio** | Personal — website | Next.js 16, Tailwind v4, Radix, Motion |
| **snainm** | Personal — ML competition | PyTorch, scikit-learn, XGBoost, LightGBM, Transformers, Optuna |
| **malevich** | Personal — ML research | PyTorch, W&B, TensorBoard |
| **superconductors** | Personal — ML/data science | scikit-learn, XGBoost, LightGBM, SHAP, Optuna |

## Tier 1 — High impact, daily use across multiple projects

| Skill | Why | Install |
|---|---|---|
| **Vercel AI SDK** | `ai` / `@ai-sdk/*` used in 3 projects. Official skill — streaming, tool use, provider patterns. | `npx skills add vercel/ai@ai-sdk -g -y` |
| **Supabase Postgres Best Practices** | 49K installs. valuesync_os runs on Supabase (migrations, auth, RLS). Official. | `npx skills add supabase/agent-skills@supabase-postgres-best-practices -g -y` |
| **Next.js App Router Patterns** | 10K installs. Most-used framework across 4 projects — RSC, server actions, layouts, caching. | `npx skills add wshobson/agents@nextjs-app-router-patterns -g -y` |
| **Vercel React Best Practices** | 246K installs — most popular skill on the platform. Every frontend project is React. | `npx skills add vercel-labs/agent-skills@vercel-react-best-practices -g -y` |

## Tier 2 — High impact, scoped to specific projects

| Skill | Why | Install |
|---|---|---|
| **Playwright Best Practices** | 15K installs. Nexus frontend has e2e tests with Playwright. Selectors, fixtures, page objects. | `npx skills add currents-dev/playwright-best-practices-skill@playwright-best-practices -g -y` |
| **FastAPI** | Nexus backend is FastAPI + SQLAlchemy + async. Official skill from the FastAPI repo. | `npx skills add fastapi/fastapi@fastapi -g -y` |
| **Tailwind v4 + shadcn** | 2.7K installs. Tailwind v4 in micio, Radix/shadcn patterns everywhere. | `npx skills add jezweb/claude-skills@tailwind-v4-shadcn -g -y` |
| **Webapp Testing** | 32K installs, from Anthropic. valuesync_os has Vitest + Stryker mutation testing. | `npx skills add anthropics/skills@webapp-testing -g -y` |

## Tier 3 — Useful, narrower scope

| Skill | Why | Install |
|---|---|---|
| **Python Testing Patterns** | 10K installs. snainm and malevich both have pytest setups. Fixtures, parametrize, mocking. | `npx skills add wshobson/agents@python-testing-patterns -g -y` |
| **Python Performance Optimization** | 12K installs. ML projects do heavy numerical work — profiling, vectorization, memory. | `npx skills add wshobson/agents@python-performance-optimization -g -y` |
| **TypeScript Advanced Types** | 18K installs. Complex TS across all frontend projects. Utility types, generics, discriminated unions. | `npx skills add wshobson/agents@typescript-advanced-types -g -y` |
| **Docker Expert** | 8K installs. Nexus has docker-compose + Dockerfiles for frontend and backend. | `npx skills add sickn33/antigravity-awesome-skills@docker-expert -g -y` |

## Skipped

- **Pydantic AI skills** — low install counts, likely low-quality or stale.
- **ML-specific skills** (PyTorch, XGBoost) — nothing with meaningful adoption. Python performance/testing skills cover the gap.
- **Next.js Supabase Auth** — overlaps with official Supabase skill; valuesync_os already has its own auth setup.
- **React Native** — no mobile projects.
