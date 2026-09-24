# Current Working State

Last verified: 2026-09-20. Regenerate tables: `python3 tools/gen-docs.py`. Check drift: `python3 tools/gen-docs.py --check`.

## Topology

<!-- generated:topology -->
| container | role | ports |
|---|---|---|
| agent-gate-proxy-1 | Go proxy | 8080->8080 |
| agent-gate-agentgate-1 | Zig policy engine | 8081->8080, 9090->9090 |
| agent-gate-litellm | LiteLLM gateway | 4000->4000 |
| agent-gate-license-server-1 | License server | 4001->4001 |
<!-- generated-end -->

## Endpoints

<!-- generated:endpoints -->
| method | url | purpose |
|---|---|---|
| POST | localhost:8080/v1/messages | Chat path (proxy) |
| POST | localhost:8081/check | Policy decision (agentgate) |
| GET | localhost:8081/denied-requests | Denial audit (agentgate) |
| GET | localhost:8081/metrics | Prometheus (agentgate) |
| GET | localhost:8080/health | Proxy health |
<!-- generated-end -->

## Policy set

Runtime file: `policies/ai-agent.json` (mounted into agentgate-1 via `AGENTGATE_POLICY_POLICY_FILE`). Engine default-denies on no match (`src/policy/types.zig:306`).

<!-- generated:policy-table -->
| id | effect | match |
|---|---|---|
| block-rm | deny | tool=bash, command_pattern=rm  |
| block-rmdir | deny | tool=bash, command_pattern=rmdir |
| block-unlink | deny | tool=bash, command_pattern=unlink |
| block-shred | deny | tool=bash, command_pattern=shred |
| block-find-delete | deny | tool=bash, command_pattern=-delete |
| block-truncate | deny | tool=bash, command_pattern=truncate |
| block-null-trunc | deny | tool=bash, command_pattern=/dev/null |
| block-clobber | deny | tool=bash, command_pattern=:> |
| block-mke2fs | deny | tool=bash, command_pattern=mke2fs |
| block-wipefs | deny | tool=bash, command_pattern=wipefs |
| block-fdisk | deny | tool=bash, command_pattern=fdisk |
| block-parted | deny | tool=bash, command_pattern=parted |
| block-chown-r | deny | tool=bash, command_pattern=chown -R |
| block-chmod-r | deny | tool=bash, command_pattern=chmod -R |
| block-git-clean | deny | tool=bash, command_pattern=git clean -f |
| block-rimraf | deny | tool=bash, command_pattern=rimraf |
| block-rmtree | deny | tool=bash, command_pattern=rmtree |
| block-os-remove | deny | tool=bash, command_pattern=os.remove |
| block-shutil | deny | tool=bash, command_pattern=shutil |
| block-fs-rm | deny | tool=bash, command_pattern=fs.rm |
| block-wipe | deny | tool=bash, command_pattern=wipe  |
| block-root | deny | path_pattern=/root/* |
| block-boot | deny | path_pattern=/boot/* |
| block-mkfs | deny | tool=bash, command_pattern=mkfs |
| block-dd | deny | tool=bash, command_pattern=dd  |
| block-forkbomb | deny | command_pattern=(){ |
| block-etc | deny | path_pattern=/etc/* |
| block-env-access | deny | command_pattern=.env |
| block-ssh-keys | deny | tool=read, path_pattern=~/.ssh/ |
| block-aws-creds | deny | tool=read, path_pattern=~/.aws/ |
| block-home-read | deny | tool=read, path_pattern=/home/ |
| allow-bash | allow | tool=bash |
| allow-read-workspace | allow | tool_pattern=read_*, path_pattern=/workspace/* |
| allow-read | allow | tool=read, path_pattern=/workspace/* |
| allow-write-workspace | allow | tool=write, path_pattern=/workspace/* |
| allow-edit-workspace | allow | tool=edit, path_pattern=/workspace/* |

Count: 36
<!-- generated-end -->

## Observe

- Denials live: `docker logs agent-gate-agentgate-1 | grep "IO IN"` (headers+body) and `grep "IO OUT"` (decision+policy+response). Gated by `ENABLE_IO_DUMP` in `src/server/http.zig`.
- Denial audit API: `curl localhost:8081/denied-requests?limit=20`.
- Counters: `curl localhost:9090/metrics`.
- Proxy logs edge metadata only; agentgate-1 is canonical for denials.
