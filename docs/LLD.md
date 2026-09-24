# Low-Level Design

Per-module map with key functions. Line refs as of 2026-09-20; use grep to re-pin.

## `src/server/http.zig` (live path, thread-pool + epoll)

- `handleRequestThread`: read 8KB stack buffer -> `parseHttpRequestFast` -> TLS/admin/hosted branches -> route. Keep-alive loop, 100 req cap.
- `parseHttpRequestFast`: zero-alloc split into method/path/query/body/headers; `detectKeepAlive` (stdlib `eqlIgnoreCase`).
- `parseCheckRequestFast` + `scanJsonStringValue`: tolerant string scanner, raw escaped text preserved for substring match.
- `handleCheckRequest`: context build -> `evaluateWithTimeout` -> allow/deny JSON; deny records tracker entry.
- `handleDeniedRequests`: `limit/agent/since` query over ring.
- `sendJsonResponse` / `sendErrorResponse`: single-buffer writes.
- `ENABLE_IO_DUMP` + `redactHeaders`: `/check`-only stderr dump; masks `x-api-key`, `authorization`, cert, cookie values.
- Dead/alternate: `http_async.zig` (`--async-io` only), `http_uring.zig` (unreferenced).

## `src/policy/` (engine)

- `types.zig:matchesCommandPattern`: substring; `matchesPathPattern`: prefix/substring; `matchesToolPattern`: exact/`prefix_*`; `matchesAgentId`: exact/`*`. AND across conditions.
- `engine.zig:evaluate`: first-match-wins; `PolicySet.evaluateWithTimeout`; no-match -> `Decision.deny("default-deny")`.
- `parser.zig`: runtime JSON parse; `parseComptime` for tests.

## `src/denial_tracker.zig`

- `DenialRecord`: bounded fixed-size fields; `DenialTracker.record` (mutex, ring 1000); `getRecent(limit, agent, since)`; global singleton `initGlobal` (`main.zig:80`).

## `proxy/` (Go)

- `main.go:handleMessages`, `filterNonStreamingResponse`, `withLogging`.
- `policy/client.go:Check`, `upstream/client.go:ForwardStreamFiltered`, `anthropic/sse.go` denial-text injection.
- No `POLICY DENY` log lines (agentgate-1 canonical).

## Policy reference (generated)

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
