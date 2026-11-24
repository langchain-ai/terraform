"""The settings an install cannot run without, asked once and kept in infra/terraform.tfvars.

    python3 settings.py TFVARS [--interactive]

For each question in order, the answer is the first of: the value already in the tfvars; the same
name given on the command line (make up box=m ssh_host=lab1); the person's answer at the prompt
(--interactive). A name given on the command line replaces the value in the file, so the file always
says what the install is. Without a terminal, or with YES=1, nothing is asked: a setting with a
default keeps it, and one without (ssh_host, a cluster's storage class, a domain) fails, listing the
names to pass. Every other setting is optional and documented in terraform.tfvars.example.
"""

import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

Answers = Dict[str, str]

BOLD, DIM, YELLOW, CYAN, RED, OFF = (
    ("\033[1m", "\033[2m", "\033[33m", "\033[36m", "\033[31m", "\033[0m") if os.environ.get("LITE_COLOR") == "1" else ("",) * 6
)


@dataclass
class Question:
    key: str
    prompt: str
    default: Optional[str] = None  # None: required, nothing to fall back on
    choices: tuple = ()
    when: Callable[[Answers], bool] = lambda a: True
    kind: str = "string"  # string, number or list (a list of strings, typed comma-separated)
    pattern: str = ""
    note: str = ""  # printed once before the question is asked
    optional: bool = False  # Enter keeps Terraform's default, saved as empty so it is not asked again


def ssh_key() -> Optional[str]:
    for name in ("id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"):
        path = os.path.expanduser(f"~/.ssh/{name}")
        if os.path.exists(path):
            return open(path).read().strip()
    return None


QUESTIONS = [
    Question("name", "the install's name", "langsmith-lite", pattern=r"^[a-z][a-z0-9-]{0,40}$"),
    Question("cloud", "where it runs", "baremetal", ("baremetal", "aws", "cluster"),
             note="baremetal: a Linux machine you ssh to; aws: an instance this makes; cluster: files for your own Kubernetes"),
    Question("ssh_host", "the machine's address, or an alias in ~/.ssh/config", when=lambda a: a["cloud"] == "baremetal"),
    Question("ssh_user", "the ssh user, with sudo (Enter: your ssh config's, or your own name)", "", when=lambda a: a["cloud"] == "baremetal", optional=True),
    Question("aws_region", "AWS region", "us-east-1", when=lambda a: a["cloud"] == "aws"),
    Question("ssh_public_key", "the ssh public key for the instance", ssh_key(), when=lambda a: a["cloud"] == "aws"),
    Question("admin_cidrs", "addresses allowed to ssh, comma-separated CIDRs", when=lambda a: a["cloud"] == "aws", kind="list"),
    Question("storage_class", "the cluster's storage class for the stores", when=lambda a: a["cloud"] == "cluster"),
    Question("scratch_storage_class", "the storage class for caches", when=lambda a: a["cloud"] == "cluster"),
    Question("box", "the size", "s", ("xs", "s", "m", "l"),
             note="xs 2 vCPU 16 GiB 1 run/s; s 4/16 5; m 8/32 25; l 16/64 50 (README.md, Sizes)"),
    Question("short_ttl_days", "days a trace is kept", "14", kind="number", pattern=r"^[1-9][0-9]*$",
             note="Retention sizes the disk more than anything else: choose what you must keep."),
    Question("long_ttl_days", "days an extended trace is kept, 14 or more", "30", kind="number", pattern=r"^[1-9][0-9]*$"),
    Question("access", "how LangSmith is reached", "localhost", ("localhost", "ip", "dns", "tunnel"),
             when=lambda a: a["cloud"] != "cluster", note="OPERATE.md, Reaching it"),
    Question("domain", "LangSmith's domain", when=lambda a: a.get("access") in ("dns", "tunnel")),
    Question("acme_email", "email for Let's Encrypt", when=lambda a: a.get("access") == "dns"),
    Question("admin_email", "the first admin's login email", "admin@langsmith.lite", pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$"),
]

LINE = re.compile(r"^([a-z_]+)\s*=\s*(.*?)\s*(#.*)?$")


def read_tfvars(path: str) -> Answers:
    """Top-level assignments only: a value is kept as written, its quotes taken off."""
    found: Answers = {}
    if os.path.exists(path):
        for line in open(path):
            m = LINE.match(line)
            if m:
                found[m.group(1)] = m.group(2).strip('"')
    return found


def hcl(q: Question, value: str) -> str:
    if q.kind == "number":
        return value
    if q.kind == "list":
        items = [v.strip().strip('"') for v in value.strip("[]").split(",") if v.strip()]
        return "[" + ", ".join(f'"{v}"' for v in items) + "]"
    return f'"{value}"'


def valid(q: Question, value: str) -> bool:
    if q.choices and value not in q.choices:
        return False
    return not q.pattern or re.match(q.pattern, value) is not None


def ask(q: Question, answers: Answers) -> str:
    default = q.default
    if q.key == "scratch_storage_class":
        default = answers.get("storage_class")
    if q.note:
        print(f"\n  {YELLOW if q.key == 'short_ttl_days' else DIM}{q.note}{OFF}", file=sys.stderr)
    hint = f" ({', '.join(q.choices)})" if q.choices else ""
    shown = f" {DIM}[{default if len(default or '') < 40 else default[:37] + '...'}]{OFF}" if default else ""
    while True:
        value = input(f"  {CYAN}{q.key:<22}{OFF} {q.prompt}{hint}{shown}: ").strip() or (default or "")
        if (value or q.optional) and (not value or valid(q, value)):
            return value
        print(f"  {RED}not a valid {q.key}{OFF}" if value else f"  {RED}{q.key} is required{OFF}", file=sys.stderr)


def settle(path: str, interactive: bool) -> int:
    in_file = read_tfvars(path)
    answers: Answers = {}
    write: Dict[str, str] = {}
    missing: List[str] = []
    for q in QUESTIONS:
        if not q.when(answers):
            continue
        given = os.environ.get(q.key)
        if given is not None:
            if not valid(q, given):
                print(f"  {RED}{q.key}={given} is not valid{OFF}", file=sys.stderr)
                return 1
            answers[q.key] = write[q.key] = given
        elif q.key in in_file:
            answers[q.key] = in_file[q.key]
        elif interactive:
            answers[q.key] = write[q.key] = ask(q, answers)
        elif q.default is not None:
            answers[q.key] = q.default  # Terraform's own default applies; nothing written
        else:
            missing.append(q.key)
    if missing:
        print(f"\n  {RED}ERROR{OFF}  infra/terraform.tfvars has no {', '.join(missing)}", file=sys.stderr)
        print(f"         pass them once, e.g. make up {' '.join(k + '=...' for k in missing)}, or run make up at a terminal\n", file=sys.stderr)
        return 1
    save(path, {q.key: hcl(q, write[q.key]) for q in QUESTIONS if q.key in write})
    return 0


def save(path: str, values: Dict[str, str]) -> None:
    if not values:
        return
    lines = open(path).read().splitlines() if os.path.exists(path) else [
        "# This install's settings, written by make plan and make up from their questions. Edit freely;",
        "# every other setting, with what it does: terraform.tfvars.example and variables.tf.",
        "",
    ]
    for key, value in values.items():
        at = next((i for i, line in enumerate(lines) if (m := LINE.match(line)) and m.group(1) == key), None)
        if at is None:
            lines.append(f"{key} = {value}")
        else:
            lines[at] = f"{key} = {value}"
    old = os.umask(0o077)
    try:
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
    finally:
        os.umask(old)
    print(f"\n  {DIM}saved {', '.join(values)} in infra/terraform.tfvars{OFF}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(settle(sys.argv[1], "--interactive" in sys.argv[2:]))
