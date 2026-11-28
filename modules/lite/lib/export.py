# MIT License - Copyright (c) 2026 LangChain, Inc.
# NOTICE: Actively being tested and subject to change. Not officially supported by LangChain.
# See LICENSE at the root of this repository for full license text.

"""Write an install's releases for a Kubernetes cluster of one's own: make export.

    python3 export.py <out> <values.json> <export.json>

values.json is Terraform's `values` output (each release's chart, namespace, values and values layer, in
install order); export.json its `export` output (the namespaces and priority class, the Secrets, the
datastores chart's package name). Writes:

    cluster.yaml          the namespaces and the stores' priority class
    secrets.yaml          every Secret the releases read (mode 600: delete it once applied)
    values/NN-<name>.yaml each release's values, and its second layer where it has one
    install.sh            one `helm upgrade --install` a release, in install order

and prints the datastores chart's package name, which the caller copies into charts/.
Standard library only.
"""

import json
import os
import sys
from pathlib import Path


def helm_line(name: str, release: dict, base: str) -> str:
    chart = release["chart"]
    if "repo" in chart:
        source = f"{chart['chart']} --repo {chart['repo']} --version {chart['version']}"
    else:
        # The bare-metal module's datastores chart, shipped beside the values.
        source = f"charts/{os.path.basename(chart['chart'])}"
    files = f"-f {base}.yaml" + (f" -f {base}.layer.yaml" if release["layer"] else "")
    return f"helm upgrade --install {name} {source} -n {release['namespace']} {files} --wait --timeout 20m"


def main() -> int:
    out, values_path, export_path = sys.argv[1:4]
    releases = json.loads(Path(values_path).read_text())
    export = json.loads(Path(export_path).read_text())
    os.makedirs(os.path.join(out, "values"), exist_ok=True)

    lines = [
        "#!/usr/bin/env bash",
        "# The releases in install order, the stores first; run it again to upgrade.",
        "# Apply cluster.yaml and secrets.yaml first.",
        "set -euo pipefail",
        'cd "$(dirname "$0")"',
    ]
    for i, (name, release) in enumerate(releases.items()):
        base = f"values/{i:02d}-{name}"
        with open(os.path.join(out, f"{base}.yaml"), "w") as f:
            json.dump(release["values"], f, indent=2)
        if release["layer"]:
            with open(os.path.join(out, f"{base}.layer.yaml"), "w") as f:
                f.write(release["layer"])
        lines.append(helm_line(name, release, base))

    with open(os.path.join(out, "install.sh"), "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(os.path.join(out, "install.sh"), 0o700)
    with open(os.path.join(out, "cluster.yaml"), "w") as f:
        f.write(export["cluster_yaml"])
    fd = os.open(os.path.join(out, "secrets.yaml"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(export["secrets_yaml"])
    print(export["datastores_tgz"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
