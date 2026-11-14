"""Report transient /etc observations, not just surviving overlay entries.

Based on PR #17's collector and PR #18's operation inventory. Raw audit
events remain the source of truth: relative dirfd paths and service identity
often cannot be reconstructed. Never join by basename or reused PID.
"""

import os
import re
import stat
import subprocess
from collections import defaultdict

AUDIT_KEY = "atomic-linux-etc"
ETC = "/etc"
ENCODED_FIELDS = {"comm", "exe", "name", "cwd", "cgroup"}
FIELD_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')
SERIAL_RE = re.compile(r"msg=audit\(([\d.]+:\d+)\)")
HEX_RE = re.compile(r"^(?:[0-9A-Fa-f]{2})+$")


def run(*argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=60)


def checked(*argv):
    result = run(*argv)
    if result.returncode:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def upperdir():
    options = checked("findmnt", "-no", "OPTIONS", ETC).strip()
    for option in options.split(","):
        if option.startswith("upperdir="):
            upper = option.removeprefix("upperdir=")
            if not os.path.isdir(upper):
                raise RuntimeError(f"upperdir is not accessible: {upper}")
            return upper
    raise RuntimeError(f"{ETC} has no overlay upperdir (options: {options!r})")


def upper_entries(upper):
    """Yield (path under /etc, kind), failing rather than hiding read errors."""
    def walk_error(error):
        raise error

    for root, dirs, files in os.walk(upper, onerror=walk_error):
        for name in sorted(dirs) + sorted(files):
            full = os.path.join(root, name)
            st = os.lstat(full)
            if stat.S_ISCHR(st.st_mode) and st.st_rdev == 0:
                kind = "whiteout"
            elif stat.S_ISDIR(st.st_mode):
                kind = "dir"
            elif stat.S_ISLNK(st.st_mode):
                kind = "symlink"
            else:
                kind = "file"
            yield os.path.join(ETC, os.path.relpath(full, upper)), kind


def field_value(name, raw):
    if raw.startswith('"'):
        return raw[1:-1]
    if name in ENCODED_FIELDS and HEX_RE.fullmatch(raw):
        return bytes.fromhex(raw).decode(errors="replace")
    return raw


def parse_events(text):
    events = defaultdict(lambda: {"syscall": {}, "cwd": "?", "paths": []})
    for line in text.splitlines():
        serial = SERIAL_RE.search(line)
        if not serial:
            continue
        event = events[serial.group(1)]
        fields = {k: field_value(k, v) for k, v in FIELD_RE.findall(line)}
        if fields.get("type") == "SYSCALL":
            event["syscall"] = fields
        elif fields.get("type") == "CWD":
            event["cwd"] = fields.get("cwd", "?")
        elif fields.get("type") == "PATH":
            # Count null names and PARENT operands too: SYSCALL items counts
            # PATH records, not just the paths useful in the operation table.
            event["paths"].append(fields)
    return events


def incomplete_event(event):
    """Check item identities as well as counts; duplicates cannot hide loss."""
    sc = event["syscall"]
    paths = event["paths"]
    try:
        expected = int(sc["items"])
        indexes = [int(path["item"]) for path in paths]
    except (KeyError, ValueError):
        return True
    return (expected < 0 or len(indexes) != expected
            or set(indexes) != set(range(expected)))


def audit_events():
    result = run("ausearch", "--input-logs", "--raw", "-k", AUDIT_KEY, "-ts", "boot")
    # Exit 1 can mean an error as well as no matches. Neither can validate
    # collection: the VM deliberately creates/deletes a probe this boot.
    if result.returncode:
        raise RuntimeError(f"ausearch failed/no records ({result.returncode}): {result.stderr.strip()}")
    events = parse_events(result.stdout)
    if not any(e["syscall"].get("key") == AUDIT_KEY for e in events.values()):
        raise RuntimeError("no keyed syscall records; audit collection is unverified")
    return events


def writer(event):
    sc = event["syscall"]
    # Only evidence carried by this event, never current /proc or a journal
    # lookup by PID. A recorded systemd cgroup can identify a service even
    # when the event has no explicit unit. Do not infer units from programs.
    unit = sc.get("unit")
    cgroup = sc.get("cgroup", "")
    services = [part for part in cgroup.split("/") if part.endswith(".service")]
    if unit:
        attribution = f"recorded unit: {unit}"
    elif cgroup.startswith("/") and len(services) == 1:
        attribution = f"recorded cgroup unit: {services[0]} (cgroup {cgroup})"
    else:
        attribution = "service unknown (no event-time unit)"
    return f"{sc.get('exe', '?')} ({sc.get('comm', '?')}, pid {sc.get('pid', '?')}); {attribution}"


def observations(events):
    """Keep each operation, including deleted paths and failed attempts."""
    rows = []
    for serial, event in sorted(events.items()):
        sc = event["syscall"]
        if sc.get("key") != AUDIT_KEY:
            continue
        outcome = {"yes": "successful watched operation", "no": "failed attempt"}.get(
            sc.get("success"), "outcome unknown")
        for fields in event["paths"]:
            if fields.get("nametype") == "PARENT" or fields.get("name", "(null)") == "(null)":
                continue
            name = fields["name"]
            # Relative PATH names may use openat/renameat dirfds, not CWD.
            if name.startswith("/"):
                path = os.path.normpath(name)
                if path != ETC and not path.startswith(ETC + "/"):
                    continue
                resolution = "absolute audit path"
            else:
                path = name
                resolution = f"unresolved relative path (cwd {event['cwd']}; dirfd unknown)"
            rows.append((path, resolution, outcome,
                         fields.get("nametype", "UNKNOWN"),
                         f"{serial}; arch={sc.get('arch', '?')} syscall={sc.get('syscall', '?')}",
                         writer(event)))
    return rows


def cell(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(
        ">", "&gt;").replace("|", "&#124;").replace("\n", " ").replace("\r", " ").replace("`", "&#96;")


def render_report(upper, entries, events, audit_status, audit_rules, watch_status):
    rows = observations(events)
    successful = {r[0] for r in rows if r[1] == "absolute audit path"
                  and r[2] == "successful watched operation"}
    incomplete = [serial for serial, event in events.items() if incomplete_event(event)]
    lines = [f"Upperdir: `{cell(upper)}`; {len(entries)} entries; {len(events)} audit events.",
             "", "## Coverage and limitations", "",
             "This is an observation window, not proof of every /etc mutation. "
             "Successful watched syscalls are distinct from failed attempts; "
             "NORMAL paths may be operands, not modified files. CREATE/DELETE "
             "include rename endpoints. Parent copy-ups do not identify writers.",
             "", "Early-boot gap: initramfs and writes before the early watch are not observed. "
             "audit-rules reload removes/reinstalls the watch; task,never can leave "
             "processes without audit contexts. Nested mounts may escape the watch. "
             "Audit loss/backlog below is a snapshot, not a guarantee of completeness. "
             "Relative dirfd paths remain unresolved. No basename or PID/parent "
             "heuristic is used; service attribution requires event-time unit/cgroup evidence.",
             "", f"Incomplete event groups: {len(incomplete)} (possible collection gap).",
             "SYSCALL items must match all PATH item indexes, including null/PARENT records. "
             "Missing or malformed item metadata is also incomplete.", ""]
    for serial in incomplete:
        event = events[serial]
        lines.append(f"- Event {cell(serial)}: expected items={cell(event['syscall'].get('items', '?'))}; "
                     f"received PATH indexes={cell([p.get('item', '?') for p in event['paths']])}")
    lines.append("")
    for title, value in (("Audit status (lost/backlog/enabled)", audit_status),
                         ("Active audit rules", audit_rules),
                         ("Early watch unit", watch_status)):
        lines += [f"### {title}", "", "<pre>", cell(value), "</pre>", ""]
    lines += ["## Audit-observed operations (including paths absent from upperdir)", "",
              "| Path | Resolution | Result | PATH type | Event / syscall | Writer |",
              "| --- | --- | --- | --- | --- | --- |"]
    lines += ["| " + " | ".join(map(cell, row)) + " |" for row in rows]
    lines += ["", "## Final upperdir inventory", "",
              "| Path | Kind | Attribution |", "| --- | --- | --- |"]
    for path, kind in sorted(entries):
        attribution = "see successful audit operations above" if path in successful else "unattributed (upperdir only)"
        lines.append(f"| {cell(path)} | {cell(kind)} | {attribution} |")
    return "\n".join(lines)


def require_early_watch():
    watch = checked("systemctl", "show", "atomic-linux-etc-watch.service",
                    "-p", "ActiveState", "-p", "SubState", "-p", "Result",
                    "-p", "ExecMainStatus", "-p", "ConditionResult",
                    "-p", "ActiveEnterTimestampMonotonic")
    fields = dict(line.split("=", 1) for line in watch.splitlines() if "=" in line)
    required = {"ActiveState": "active", "SubState": "exited", "Result": "success",
                "ExecMainStatus": "0", "ConditionResult": "yes"}
    try:
        activated = int(fields.get("ActiveEnterTimestampMonotonic", "0")) > 0
    except ValueError:
        activated = False
    if not activated or any(fields.get(key) != value for key, value in required.items()):
        raise RuntimeError(f"early /etc watch did not activate successfully: {watch.strip()}")
    return watch


def main():
    upper = upperdir()
    status = checked("auditctl", "-s")
    rules = checked("auditctl", "-l")
    if not any(AUDIT_KEY in line and "-w /etc " in line and "-p wa" in line
               for line in rules.splitlines()):
        raise RuntimeError("expected /etc write/attribute audit watch is missing")
    watch = require_early_watch()
    events = audit_events()
    probe = "/etc/atomic-linux-transient-etc-audit-probe"
    if not any(row[0] == probe and row[2] == "successful watched operation"
               for row in observations(events)):
        raise RuntimeError("audit probe not observed; collector acceptance failed")
    print(render_report(upper, list(upper_entries(upper)), events, status, rules, watch))


if __name__ == "__main__":
    main()
