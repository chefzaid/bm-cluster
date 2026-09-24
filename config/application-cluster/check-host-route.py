"""Executed in a target node's network namespace; contains no credentials."""
import json
from pathlib import Path
import socket
import subprocess

settings = json.loads(Path("/check/config.json").read_text())
if settings["interface"] != "tailscale0":
    raise SystemExit("Only the managed Tailscale transport is supported")
if settings.get("localAddress"):
    output = subprocess.run(["ip", "-4", "address", "show", "dev", "tailscale0"], capture_output=True, text=True, check=True).stdout
    if "inet " + settings["localAddress"] + "/" not in output:
        raise SystemExit("Declared gateway node does not own the Tailscale gateway address")
for answer in socket.getaddrinfo(settings["address"], None, type=socket.SOCK_STREAM):
    address = answer[4][0]
    result = subprocess.run(["ip", "route", "get", address], capture_output=True, text=True, check=True)
    if "dev tailscale0" not in result.stdout.splitlines()[0]:
        raise SystemExit("Shared service/API traffic is not routed over tailscale0")
print("Encrypted transport route verified")
