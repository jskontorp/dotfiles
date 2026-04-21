## Graveyard

Retired pi extensions. Kept around for reference / easy resurrection.

`install.sh` only globs `*.ts` directly inside `pi/agent/extensions/`, so files
in this subdirectory are not symlinked into `~/.pi/agent/extensions/` and pi
will not load them.

### Retired

- **`query-image.ts`** — routed image files through a GitHub Copilot
  (Codex/GPT) vision model because Anthropic vision was blocked on the org's
  Copilot proxy. Retired 2026-04-21: image reading is now natively supported,
  so `read` works on `.png`/`.jpg`/etc. directly and no shim is needed.
