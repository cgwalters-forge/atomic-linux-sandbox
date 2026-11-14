"""List what this boot wrote to a transient /etc, and who wrote it.

Run as root inside a transient-/etc VM by transient-etc-vm-test.sh. Every
entry in the /etc overlay's upperdir is a runtime write; each is joined with
the records of the image's audit watch (key atomic-linux-etc) by path. An
entry with no matching record, such as one written in the initramfs before
the watch was loaded, is listed as unattributed. Prints Markdown.
"""

import os
import re
import stat
import subprocess
import sys
from collections import defaultdict

AUDIT_KEY = "atomic-linux-etc"
ETC = "/etc"
# Fields that auditd hex-encodes when they contain spaces or quotes.
ENCODED_FIELDS = {"comm", "exe", "name", "cwd"}
FIELD_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')
SERIAL_RE = re.compile(r"msg=audit\([\d.]+:(\d+)\)")
HEX_RE = re.compile(r"^(?:[0-9A-F]{2})+$")


def run(*argv):
    return subprocess.run(argv, capture_output=True, text=True)


def upperdir():
    options = run("findmnt", "-no", "OPTIONS", ETC).stdout.strip()
    for option in options.split(","):
        if option.startswith("upperdir="):
            return option.removeprefix("upperdir=")
    sys.exit(f"error: {ETC} has no overlay upperdir (options: {options!r})")


def upper_entries(upper):
    """Yield (path under /etc, kind) for everything in the upperdir."""
    for root, dirs, files in os.walk(upper):
        for name in sorted(dirs) + sorted(files):
            full = os.path.join(root, name)
            st = os.lstat(full)
            if stat.S_ISCHR(st.st_mode) and st.st_rdev == 0:
                kind = "deleted"
            elif stat.S_ISDIR(st.st_mode):
                kind = "dir"
            elif stat.S_ISLNK(st.st_mode):
                kind = "symlink"
            else:
                kind = "file"
            yield os.path.join(ETC, os.path.relpath(full, upper)), kind


def field_value(name, raw):
    if raw.startswith('"'):
        return raw.strip('"')
    if name in ENCODED_FIELDS and HEX_RE.match(raw):
        return bytes.fromhex(raw).decode(errors="replace")
    return raw


def audit_events():
    """Return {serial: {"syscall": fields, "cwd": str, "names": [str]}}."""
    result = run("ausearch", "--input-logs", "--raw", "-k", AUDIT_KEY, "-ts", "boot")
    # ausearch exits 1 when nothing matches.
    if result.returncode not in (0, 1):
        print(f"**ausearch failed** ({result.returncode}): {result.stderr.strip()}\n")
    events = defaultdict(lambda: {"syscall": {}, "cwd": "/", "names": []})
    for line in result.stdout.splitlines():
        serial = SERIAL_RE.search(line)
        if not serial:
            continue
        event = events[serial.group(1)]
        fields = {k: field_value(k, v) for k, v in FIELD_RE.findall(line)}
        rtype = fields.get("type")
        if rtype == "SYSCALL":
            event["syscall"] = fields
        elif rtype == "CWD":
            event["cwd"] = fields.get("cwd", "/")
        elif rtype == "PATH" and fields.get("nametype") != "PARENT":
            if fields.get("name", "(null)") != "(null)":
                event["names"].append(fields["name"])
    return events


units = {}


def unit_of(pid, comm=None):
    """The systemd unit of a pid: from /proc while it still runs (and, if
    given, has the same comm), else from what it logged to the journal."""
    if (pid, comm) in units:
        return units[pid, comm]
    unit = ""
    try:
        with open(f"/proc/{pid}/comm") as f:
            alive = comm is None or f.read().strip() == comm
        if alive:
            with open(f"/proc/{pid}/cgroup") as f:
                unit = f.read().strip().rsplit("/", 1)[-1]
    except OSError:
        pass
    if not unit:
        out = run("journalctl", "-b", f"_PID={pid}", "-n", "1", "-o", "export").stdout
        for line in out.splitlines():
            if line.startswith(("_SYSTEMD_UNIT=", "_SYSTEMD_USER_UNIT=")):
                unit = line.split("=", 1)[1]
                break
    units[pid, comm] = unit
    return unit


def writer(event):
    sc = event["syscall"]
    comm = sc.get("comm", "?")
    unit = unit_of(sc.get("pid"), comm)
    # A parent other than PID 1 (whose unit, init.scope, says nothing),
    # e.g. the service behind a helper process that has exited.
    ppid = sc.get("ppid")
    if not unit and ppid != "1" and (parent := unit_of(ppid)):
        unit = f"parent in {parent}"
    text = f"`{sc.get('exe', '?')}` ({comm})"
    return f"{text} [{unit}]" if unit else text


def main():
    upper = upperdir()
    events = audit_events()
    by_path, by_base = defaultdict(set), defaultdict(set)
    for event in events.values():
        if not event["syscall"]:
            continue
        who = writer(event)
        for name in event["names"]:
            path = os.path.normpath(os.path.join(event["cwd"], name))
            by_path[path].add(who)
            if not name.startswith("/"):
                by_base[os.path.basename(name)].add(who)

    rows, unattributed = [], 0
    for path, kind in sorted(upper_entries(upper)):
        who = by_path.get(path)
        how = ""
        if not who and kind != "dir":
            # A name relative to a directory fd does not resolve to a full
            # path; fall back to the file name of relative names.
            who = by_base.get(os.path.basename(path))
            how = " (by name)" if who else ""
        if who:
            writers = "; ".join(sorted(who)) + how
        elif kind == "dir":
            writers = ""
        else:
            writers = "unattributed"
            unattributed += 1
        rows.append((path, kind, writers.replace("|", "\\|")))

    print(f"Upperdir `{upper}`: {len(rows)} entries, {unattributed} files unattributed; "
          f"{len(events)} audit events with key `{AUDIT_KEY}` this boot.")
    print("Directories are listed for completeness: overlayfs copies up the parents of a write.\n")
    print("| Path | Kind | Writers |")
    print("| --- | --- | --- |")
    for path, kind, writers in rows:
        print(f"| `{path}` | {kind} | {writers} |")


if __name__ == "__main__":
    main()
