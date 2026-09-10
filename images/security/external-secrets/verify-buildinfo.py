#!/usr/bin/env python3
"""Verify that the compiled ESO binary actually contains the patched modules."""
import json
from pathlib import Path
import sys


def main():
    lines = Path(sys.argv[1]).read_text().splitlines()
    if not lines or not lines[0].endswith("go1.26.7"):
        raise SystemExit("Expected the pinned Go 1.26.7 toolchain")
    modules = {}
    for line in lines[1:]:
        fields = line.split()
        if len(fields) >= 3 and fields[0] == "dep":
            modules[fields[1]] = fields[2]
    expected = {
        "github.com/google/cel-go": "v0.29.0",
        "go.mongodb.org/mongo-driver": "v1.17.9",
        "golang.org/x/crypto": "v0.56.0",
        "google.golang.org/grpc": "v1.83.2",
    }
    for module, version in expected.items():
        if modules.get(module) != version:
            raise SystemExit(f"Unexpected compiled dependency: {module}")
    # x/mod is used by development tooling and can be omitted by binary linking.
    if "golang.org/x/mod" in modules and modules["golang.org/x/mod"] != "v0.40.0":
        raise SystemExit("Unexpected compiled golang.org/x/mod dependency")
    application_version = sys.argv[3]
    if Path(sys.argv[2]).read_text().strip() != "external-secrets version " + application_version:
        raise SystemExit("Unexpected application --version output")
    symbol = "github.com/external-secrets/external-secrets/cmd/controller.version.str"
    if not any(line.split()[-1:] == [symbol] for line in Path(sys.argv[4]).read_text().splitlines()):
        raise SystemExit("Application version ELF symbol must be retained")
    print(json.dumps({"toolchain": "go1.26.7", "verifiedModules": expected,
                      "applicationVersion": application_version, "versionSymbolRetained": True}))


if __name__ == "__main__":
    main()
