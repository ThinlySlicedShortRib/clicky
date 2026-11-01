#!/usr/bin/env python3
"""Measures what Clicky touches while Stuck is detecting. See prove-privacy.sh.

Every number comes from outside the process being measured: lsof, nettop and
the kernel's proc_pid_rusage counters, plus fs_usage when run as root. A zero
only means something if the same instrument can read non-zero, so a negative
control runs first: a child that really writes a file and opens a socket.
"""

import argparse
import ctypes
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time

LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
RUSAGE_INFO_V4 = 4


class RusageInfoV4(ctypes.Structure):
    """struct rusage_info_v4 from sys/resource.h."""
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (field_name, ctypes.c_uint64) for field_name in (
            "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups",
            "ri_pageins", "ri_wired_size", "ri_resident_size", "ri_phys_footprint",
            "ri_proc_start_abstime", "ri_proc_exit_abstime", "ri_child_user_time",
            "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
            "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
            "ri_diskio_byteswritten", "ri_cpu_time_qos_default",
            "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
            "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
            "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive",
            "ri_billed_system_time", "ri_serviced_system_time", "ri_logical_writes",
            "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
            "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
            "ri_runnable_time",
        )
    ] + [("ri_reserved", ctypes.c_uint64 * 1)]


def disk_write_counters(process_identifier):
    usage = RusageInfoV4()
    result_code = LIBPROC.proc_pid_rusage(process_identifier, RUSAGE_INFO_V4, ctypes.byref(usage))
    if result_code != 0:
        raise RuntimeError(f"proc_pid_rusage failed for {process_identifier}: errno {ctypes.get_errno()}")
    return {"logicalWrites": usage.ri_logical_writes, "diskBytesWritten": usage.ri_diskio_byteswritten}


def lsof_lines(*arguments):
    completed = subprocess.run(["/usr/sbin/lsof", "-nP", *arguments], capture_output=True, text=True)
    return completed.stdout.splitlines()[1:]


def network_sockets(process_identifier):
    return lsof_lines("-a", "-p", str(process_identifier), "-i")


def files_open_for_writing(process_identifier):
    """Regular files whose descriptor mode is w or u."""
    writable_files = set()
    for line in lsof_lines("-p", str(process_identifier)):
        columns = line.split(None, 8)
        if len(columns) < 9:
            continue
        file_descriptor, file_type, file_name = columns[3], columns[4], columns[8]
        if file_type == "REG" and re.fullmatch(r"\d+[wu].*", file_descriptor):
            writable_files.add(file_name)
    return writable_files


def nettop_bytes(process_identifier):
    """Cumulative bytes in and out, or None if nettop has nothing for the pid."""
    completed = subprocess.run(
        ["/usr/bin/nettop", "-P", "-L", "1", "-x", "-n", "-p", str(process_identifier), "-J", "bytes_in,bytes_out"],
        capture_output=True, text=True, timeout=15,
    )
    rows = [line for line in completed.stdout.splitlines()[1:] if line.strip()]
    total_in = total_out = 0
    for row in rows:
        fields = row.split(",")
        numbers = [field for field in fields if field.strip().isdigit()]
        if len(numbers) >= 2:
            total_in += int(numbers[-2])
            total_out += int(numbers[-1])
    return {"bytesIn": total_in, "bytesOut": total_out, "rows": len(rows)}


def run_negative_control():
    """A child that does what Clicky must not. The instruments have to see it."""
    control_directory = tempfile.mkdtemp(prefix="clicky-proof-control-")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    child_source = (
        "import os,socket,sys,time\n"
        "print('ready',flush=True); sys.stdin.readline()\n"
        "connection=socket.create_connection(('127.0.0.1',%d))\n"
        "handle=open(os.path.join(%r,'written.bin'),'wb')\n"
        "handle.write(b'x'*2000000); handle.flush(); os.fsync(handle.fileno())\n"
        "print('wrote',flush=True); sys.stdin.readline()\n" % (port, control_directory)
    )
    child = subprocess.Popen(
        [sys.executable, "-I", "-c", child_source],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    child.stdout.readline()
    counters_before = disk_write_counters(child.pid)
    child.stdin.write("go\n")
    child.stdin.flush()
    child.stdout.readline()
    time.sleep(0.3)

    counters_after = disk_write_counters(child.pid)
    sockets_seen = len(network_sockets(child.pid))
    writable_seen = len(files_open_for_writing(child.pid))

    child.stdin.write("done\n")
    child.stdin.flush()
    child.wait(timeout=5)
    listener.close()
    subprocess.run(["/bin/rm", "-rf", control_directory])

    control = {
        "socketsSeen": sockets_seen,
        "filesOpenForWritingSeen": writable_seen,
        "logicalWritesDelta": counters_after["logicalWrites"] - counters_before["logicalWrites"],
        "diskBytesWrittenDelta": counters_after["diskBytesWritten"] - counters_before["diskBytesWritten"],
    }
    control["instrumentsWork"] = (
        sockets_seen > 0 and writable_seen > 0
        and (control["logicalWritesDelta"] > 0 or control["diskBytesWrittenDelta"] > 0)
    )
    return control


def run_fs_usage(process_identifier, seconds):
    """Starts fs_usage if allowed. Returns the process, or the reason it can't run."""
    if os.geteuid() != 0:
        return None, "needs root: run `sudo scripts/prove-privacy.sh` to add it"
    process = subprocess.Popen(
        ["/usr/bin/timeout" if os.path.exists("/usr/bin/timeout") else "/usr/bin/env", str(seconds), "/usr/bin/fs_usage", "-w", "-f", "filesys", str(process_identifier)]
        if os.path.exists("/usr/bin/timeout")
        else ["/usr/bin/fs_usage", "-w", "-f", "filesys", str(process_identifier)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    return process, None


FS_USAGE_WRITE_CALLS = re.compile(r"\b(write|pwrite|writev|WrData|open.*[WC]|rename|unlink|mkdir|ftruncate|fsync)\b")


def summarize_fs_usage(process):
    if process.poll() is None:
        process.terminate()
    output = process.communicate(timeout=10)[0]
    # fs_usage prints reads too, and the proof is about writes.
    write_lines = [line for line in output.splitlines() if FS_USAGE_WRITE_CALLS.search(line)]
    return {"totalLines": len(output.splitlines()), "writeLines": len(write_lines), "firstWriteLines": write_lines[:10]}


def recently_changed_files(marker_path, bundle_identifier):
    """Files carrying the bundle ID, changed since the marker. This catches
    preferences, which a daemon writes on the app's behalf, so they'd never
    show up in the app's own write counters."""
    home = os.path.expanduser("~")
    search_roots = [
        os.path.join(home, "Library", leaf)
        for leaf in ("Preferences", "Caches", "Application Support", "Saved Application State", "Logs", "HTTPStorages", "WebKit")
    ]
    existing_roots = [root for root in search_roots if os.path.isdir(root)]
    completed = subprocess.run(
        ["/usr/bin/find", *existing_roots, "-path", f"*{bundle_identifier}*", "-type", "f", "-newer", marker_path],
        capture_output=True, text=True,
    )
    return [line for line in completed.stdout.splitlines() if line]


def measure(process_identifier, seconds, bundle_identifier, label):
    marker_file = tempfile.NamedTemporaryFile(prefix="clicky-proof-marker-", delete=False)
    marker_file.close()
    time.sleep(1.1)

    counters_before = disk_write_counters(process_identifier)
    nettop_before = nettop_bytes(process_identifier)
    writable_before = files_open_for_writing(process_identifier)
    fs_usage_process, fs_usage_skip_reason = run_fs_usage(process_identifier, seconds)

    peak_sockets = 0
    socket_examples = []
    samples = 0
    new_writable_files = set()
    deadline = time.time() + seconds

    print(f"measuring {label} for {seconds:.0f}s", flush=True)
    while time.time() < deadline:
        current_sockets = network_sockets(process_identifier)
        peak_sockets = max(peak_sockets, len(current_sockets))
        if current_sockets and not socket_examples:
            socket_examples = current_sockets[:5]
        new_writable_files |= files_open_for_writing(process_identifier) - writable_before
        samples += 1
        time.sleep(1)

    counters_after = disk_write_counters(process_identifier)
    nettop_after = nettop_bytes(process_identifier)

    result = {
        "label": label,
        "processIdentifier": process_identifier,
        "seconds": seconds,
        "lsofSamples": samples,
        "peakNetworkSockets": peak_sockets,
        "socketExamples": socket_examples,
        "newFilesOpenedForWriting": sorted(new_writable_files),
        "filesAlreadyOpenForWriting": sorted(writable_before),
        "logicalWritesDelta": counters_after["logicalWrites"] - counters_before["logicalWrites"],
        "diskBytesWrittenDelta": counters_after["diskBytesWritten"] - counters_before["diskBytesWritten"],
        "nettopBytesInDelta": nettop_after["bytesIn"] - nettop_before["bytesIn"],
        "nettopBytesOutDelta": nettop_after["bytesOut"] - nettop_before["bytesOut"],
        "bundleFilesChangedOnDisk": recently_changed_files(marker_file.name, bundle_identifier) if bundle_identifier else [],
    }

    if fs_usage_process:
        result["fsUsage"] = summarize_fs_usage(fs_usage_process)
    else:
        result["fsUsage"] = {"skipped": fs_usage_skip_reason}

    os.unlink(marker_file.name)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=float, default=60)
    parser.add_argument("--label", default="Clicky")
    parser.add_argument("--bundle-identifier", default="")
    parser.add_argument("--json", required=True)
    arguments = parser.parse_args()

    control = run_negative_control()
    measurement = measure(arguments.pid, arguments.seconds, arguments.bundle_identifier, arguments.label)
    with open(arguments.json, "w") as json_file:
        json.dump({"negativeControl": control, "measurement": measurement}, json_file, indent=1)


if __name__ == "__main__":
    main()
