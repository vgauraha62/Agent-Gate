# Repo Update Plan — 2026-09-24

Goal: push local developments to GitHub with secrets and scratch excluded, README current.

## Steps

1. Resolve `task_plan.md` / `progress.md` UU conflicts → untrack both, keep local copies, ignore.
2. Rewrite `.gitignore` → secrets (`.env*`, `keys/`, `certs/`, `*.pem/key/p12`),
   planning docs (`task_plan*`, `progress*`, `findings*`, `docs/plans/`),
   logs/scratch, build artifacts, tooling noise.
3. Scrub index (`git rm --cached`, keep local): `certs/`, `.env.claude`/`.env.opencode`,
   `zig-cache/`, `zig-out/`, `graphify-out/`, `.antigravitycli/`, scratch txts/mds.
4. Rewrite root `README.md` → actual 4-container cage (proxy :8080, agentgate :8081/:9090,
   litellm :4000, license-server :4001), endpoints, 36-rule policy model, dev commands.
5. Stage new work (`docs/*.md`, ADRs, `tools/gen-docs.py`, `sse.go`, `VERSION`),
   verify (`gen-docs.py --check`, no secrets staged), commit, push `origin/main`.

## Out of scope

History rewrite for leaked secrets (rotation still required), LICENSE file, K8s manifests.
