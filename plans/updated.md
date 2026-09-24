# Update Report — 2026-09-24 (commit `06614c3`, pushed to `origin/main`)

## Done

- Conflicts resolved: `task_plan.md`, `progress.md` untracked (UU gone); local copies kept, git-ignored.
- `.gitignore` rewritten: secrets, planning docs, logs/scratch, build outputs, tooling noise.
- Scrubbed from tracking (local files kept): `certs/` (incl. `ca.key`), `.env.claude`/`.env.opencode`
  (latter held a live `OPENCODE_API_KEY`), `.zig-cache/`, `zig-out/bin/agent_gate`,
  `graphify-out/`, `.antigravitycli/`, 14 scratch files, `docs/plans/*.md`.
- `README.md` full rewrite: real architecture, ports, quickstart, API table, policy model
  (`policies/ai-agent.json`, 36 rules), config, dev (`zig build test-all`), docs index, security notes.
- Committed pending work: `docs/ARCHITECTURE.md`, `CURRENT_WORKING.md`, `HLD.md`, `LLD.md`,
  3 ADRs, `tools/gen-docs.py`, `proxy/anthropic/sse.go`, `agent-gate-portable/VERSION`.
- Verified: tree clean, `gen-docs.py --check` OK, 0 secret/junk paths tracked.

## Follow-ups

1. **Rotate credentials** — private keys/certs and an API key were once committed; removal from
   tracking does not purge history.
2. Optional history purge (`git filter-repo`) if leak audit demands it.
3. Add LICENSE file before publishing (README notes its absence).
4. Regenerate docs tables via `python3 tools/gen-docs.py` after any policy edit.
