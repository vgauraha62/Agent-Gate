#!/usr/bin/env python3
"""Regenerate machine-owned blocks inside living docs. Stdlib only."""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
POLICY_FILE = ROOT / "policies" / "ai-agent.json"

TOPOLOGY = [
    ("agent-gate-proxy-1", "Go proxy", "8080->8080"),
    ("agent-gate-agentgate-1", "Zig policy engine", "8081->8080, 9090->9090"),
    ("agent-gate-litellm", "LiteLLM gateway", "4000->4000"),
    ("agent-gate-license-server-1", "License server", "4001->4001"),
]

ENDPOINTS = [
    ("POST", "localhost:8080/v1/messages", "Chat path (proxy)"),
    ("POST", "localhost:8081/check", "Policy decision (agentgate)"),
    ("GET", "localhost:8081/denied-requests", "Denial audit (agentgate)"),
    ("GET", "localhost:8081/metrics", "Prometheus (agentgate)"),
    ("GET", "localhost:8080/health", "Proxy health"),
]

KEYS = ("tool", "tool_pattern", "command_pattern", "path_pattern", "agent_id", "path", "method")


def policy_table():
    data = json.loads(POLICY_FILE.read_text())
    out = ["| id | effect | match |", "|---|---|---|"]
    for p in data["policies"]:
        m = p.get("match", {})
        parts = [k + "=" + str(m[k]) for k in KEYS if k in m]
        out.append("| " + p["id"] + " | " + p["effect"] + " | " + ", ".join(parts) + " |")
    out.append("")
    out.append("Count: " + str(len(data["policies"])))
    return "\n".join(out)


def topology_table():
    out = ["| container | role | ports |", "|---|---|---|"]
    for name, role, ports in TOPOLOGY:
        out.append("| " + name + " | " + role + " | " + ports + " |")
    return "\n".join(out)


def endpoint_table():
    out = ["| method | url | purpose |", "|---|---|---|"]
    for method, url, purpose in ENDPOINTS:
        out.append("| " + method + " | " + url + " | " + purpose + " |")
    return "\n".join(out)


BLOCKS = {
    "policy-table": policy_table,
    "topology": topology_table,
    "endpoints": endpoint_table,
}

TARGETS = ["docs/CURRENT_WORKING.md", "docs/LLD.md"]


def render(text):
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("<!-- generated:") and line.endswith("-->"):
            name = line[len("<!-- generated:"):-len("-->")].strip()
            out.append(line)
            out.append(BLOCKS[name]())
            i += 1
            while i < len(lines) and lines[i] != "<!-- generated-end -->":
                i += 1
            if i < len(lines):
                out.append(lines[i])
                i += 1
        else:
            out.append(line)
            i += 1
    return "\n".join(out) + "\n"


def main():
    check = "--check" in sys.argv
    dirty = []
    for rel in TARGETS:
        p = ROOT / rel
        old = p.read_text()
        new = render(old)
        if new != old:
            if check:
                dirty.append(rel)
            else:
                p.write_text(new)
    if check and dirty:
        print("STALE: " + ", ".join(dirty))
        return 1
    print("OK" if check else "WROTE")
    return 0


if __name__ == "__main__":
    sys.exit(main())
