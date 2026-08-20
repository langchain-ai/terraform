#!/usr/bin/env bash
# Contract checks across the shell/HCL boundary, one provider per invocation:
#   bash agents/contracts.sh modules/aws
#
# terraform validate checks the HCL and shellcheck checks the shell; neither
# looks at the names the two exchange. Rename a variable in variables.tf and
# miss one of its readers and there are three ways to get no error: an accessor
# returns non-zero and the caller falls back to its default, a generated tfvars
# key draws "Warning: Value for undeclared variable" and exit 0, and an
# undeclared TF_VAR_* export is ignored with no output at all. The third kind
# already happened -- #140, the GCP root not declaring three secrets that
# setup-env.sh exported.
#
# Every check runs one direction: a name in use must be declared in that
# provider's infra/variables.tf. A declared variable that nothing uses is not a
# finding, since most carry defaults and correctly appear in no example.
#
# No terraform, no cloud credentials, no state: this reads files only.
#
# Exit 0 clean, 1 findings, 2 the check itself could not run (bad directory,
# unbalanced braces, an unregistered helper).
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

# The accessor helpers _common.sh defines. Check 5 asserts this list still
# matches what is actually defined, so adding a helper fails here until it is
# registered rather than passing having silently read nothing through it.
ACCESSORS="_parse_tfvar _parse_tfvar_quoted _tfvar_is_true"
# Wrappers are discovered per provider (see _wrapper_defs), but _read_tfvar is
# named here too so a provider that drops its status.sh alias does not quietly
# change what gets scanned.
WRAPPERS_KNOWN="_read_tfvar"
# Providers with no tfvars accessors at all. Skipped by name, not by an empty
# result: an empty result is also what a renamed directory or a broken scan
# looks like, and those must fail. ocp's scripts read zero tfvars keys; byoc is
# a standalone IAM root with no infra/ tree.
SKIP_PROVIDERS="byoc ocp"
# Records are tab-separated; bash 3.2 has no $'\t'.
TAB=$(printf '\t')

# ── The extractor ────────────────────────────────────────────────────────────
# One depth-aware HCL key reader, used by every check that reads HCL, so the
# checks cannot drift apart on what counts as a key.
#
# Input is numbered lines, "<lineno>\t<text>", so a finding can name the line it
# came from. Output is "<lineno>\t<name>" for every assignment at brace depth 0.
#
# Depth matters: a line grep on aws/infra/terraform.tfvars.example reports 39
# keys, five of which (name, default, instance_types, min_size, max_size) live
# inside the eks_node_groups block and are not root variables. Quoted spans come
# out before anything else so that a brace inside a string, a "${VAR}" in a
# generated heredoc, or a # inside a value cannot move the depth or fake a
# comment. Depth that has not returned to 0 at EOF means the scrubbing lost
# track, and a partial key set would silently under-report, so that exits 3.
_hcl_keys() {
  awk -F'\t' '
    {
      n = $1; s = $0; sub(/^[0-9]+\t/, "", s)
      gsub(/\\"/, "", s); gsub(/"[^"]*"/, "", s)
      sub(/#.*/, "", s); sub(/\/\/.*/, "", s)
      if (depth == 0 && s ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=[^=]/) {
        k = s; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
        print n "\t" k
      }
      depth += gsub(/[{[]/, "", s) - gsub(/[}\]]/, "", s)
    }
    END {
      if (depth != 0) {
        print "brace depth " depth " at EOF, key set would be partial" > "/dev/stderr"
        exit 3
      }
    }
  '
}

# Numbered-line view of a whole file, the input _hcl_keys expects.
_numbered() { awk '{ print NR "\t" $0 }' "$1"; }

# ── Collectors ───────────────────────────────────────────────────────────────
# Bodies of every heredoc whose redirect target resolves to a *.tfvars path,
# as numbered lines. The delimiter is read off the redirect line rather than
# hardcoded: quickstart.sh uses TFVARS and azure's setup-env.sh uses EOF. The
# target is resolved through one level of shell variable (OUTPUT, SECRETS_FILE),
# which is also what keeps a heredoc writing something other than tfvars out.
_tfvars_heredocs() {
  awk '
    { line = $0 }
    !in_hd && line ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/ {
      v = line; sub(/^[ \t]*/, "", v); sub(/=.*/, "", v)
      val = line; sub(/^[^=]*=/, "", val); gsub(/"/, "", val)
      var[v] = val
    }
    in_hd {
      t = line; if (dash) sub(/^\t+/, "", t)
      if (t == delim) { in_hd = 0; next }
      if (want) print NR "\t" line
      next
    }
    line ~ /<<-?[ \t]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?[ \t]*$/ && line !~ /<<</ {
      d = line; sub(/^.*<<-?[ \t]*/, "", d); gsub(/['"'"'"]/, "", d); sub(/[ \t]*$/, "", d)
      delim = d; dash = (line ~ /<<-/)
      tgt = line; sub(/[ \t]*<<.*$/, "", tgt); sub(/^.*>[>]?[ \t]*/, "", tgt)
      gsub(/["${}]/, "", tgt)
      if (tgt in var) tgt = var[tgt]
      want = (tgt ~ /\.tfvars$/); in_hd = 1
      next
    }
    END {
      if (in_hd) {
        print "unterminated heredoc <<" delim > "/dev/stderr"
        exit 3
      }
    }
  ' "$1"
}

# True if the script generates or edits a tfvars file: it assigns a shell
# variable to a *.tfvars path and then redirects into it or seds it in place.
# This is the gate on _quoted_tfvars_writes below -- scanning every script that
# merely mentions tfvars would read `key = \"value\"` strings that are not
# tfvars lines at all and report them as undeclared variables.
_writes_tfvars() {
  awk '
    $0 ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/ {
      v = $0; sub(/^[ \t]*/, "", v); sub(/=.*/, "", v)
      val = $0; sub(/^[^=]*=/, "", val); gsub(/"/, "", val)
      if (val ~ /\.tfvars$/) tfv[v] = 1
    }
    {
      for (v in tfv)
        if (index($0, "$" v) || index($0, "${" v "}"))
          if ($0 ~ />>?[ \t]*"?\$\{?[A-Za-z_]/ || $0 ~ /sed[ \t].*-i/) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# tfvars assignments emitted from inside a shell double-quoted string, as
# "<lineno>\t<key>". This is the write path that is not a heredoc: tls.sh seds
# acm_certificate_arn back into terraform.tfvars, and quickstart.sh echoes a
# couple of optional keys one line at a time. The escaped quote is what makes
# the match specific -- `key = \"` is a tfvars line being built in shell, where
# a bare `key =` would match half the shell in the repo.
_quoted_tfvars_writes() {
  awk '
    {
      s = $0
      while (match(s, /(^|[^A-Za-z0-9_])[a-z][a-z0-9_]*[ \t]*=[ \t]*\\"/)) {
        k = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)
        sub(/^[^a-z]/, "", k); sub(/[ \t]*=.*/, "", k)
        print NR "\t" k
      }
    }
  ' "$1"
}

# Wrapper accessors: a one-line definition that forwards $1 straight to a known
# accessor. All three status.sh files define `_read_tfvar() { _parse_tfvar "$1"; }`,
# and without following it azure reads 21 keys instead of 36.
_wrapper_defs() {
  awk -v accs="$ACCESSORS" '
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]+"?\$\{?1\}?"?[ \t]*;?[ \t]*\}/) {
      name = $0; sub(/^[ \t]*/, "", name); sub(/\(\).*/, "", name)
      body = $0; sub(/^[^{]*\{[ \t]*/, "", body); sub(/[ \t].*/, "", body)
      if (body in acc) print name
    }
  ' "$1"
}

# Accessor call sites. Emits one tab-separated record per call:
#   key   <lineno>  <key>            a literal key, checkable
#   file  <lineno>  <key>  <file>    _parse_tfvar_quoted against a named file
#   dyn   <lineno>  <text>           the key is built at runtime, not checkable
#
# Tokenized rather than pattern-matched on the whole call, because all 26
# _read_tfvar call sites pass the key bare and requiring quotes undercounts
# azure by 15 keys. A trailing identifier run is what identifies the accessor,
# so `val=$(_parse_tfvar` matches and `_read_gateway_flag` does not.
#
# An argument of exactly "$1" is a definition forwarding its own argument, not a
# read, so it is neither checked nor reported.
_accessor_calls() {
  awk -v accs="$1" '
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    /^[ \t]*#/ { next }
    /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=/ {
      v = $0; sub(/^[ \t]*/, "", v); sub(/=.*/, "", v)
      val = $0; sub(/^[^=]*=/, "", val); gsub(/"/, "", val)
      var[v] = val
    }
    {
      n2 = split($0, t, /[ \t]+/)
      for (i = 1; i <= n2; i++) {
        tok = t[i]
        if (tok ~ /\(\)$/) continue
        sub(/^.*[^A-Za-z0-9_]/, "", tok)
        if (!(tok in acc)) continue
        arg = (i < n2) ? t[i+1] : ""
        gsub(/["'"'"']/, "", arg); sub(/[);&|].*$/, "", arg)
        if (arg == "$1" || arg == "${1}") continue
        if (arg ~ /\$/) {
          src = $0; sub(/^[ \t]+/, "", src); gsub(/\t/, " ", src)
          print "dyn\t" NR "\t" src; continue
        }
        if (arg !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        f = ""
        if (t[i] ~ /_parse_tfvar_quoted$/ && i + 2 <= n2) {
          f = t[i+2]; gsub(/["'"'"']/, "", f); sub(/[);&|].*$/, "", f)
          gsub(/[${}]/, "", f)
          if (f in var) f = var[f]
        }
        if (f != "") print "file\t" NR "\t" arg "\t" f
        else print "key\t" NR "\t" arg
      }
    }
  ' "$2"
}

# ── Reporting ────────────────────────────────────────────────────────────────
findings=0
notes=""

# A name in use that infra/variables.tf does not declare.
_report() {
  findings=$((findings + 1))
  echo "$1: $2: $3 \"$4\" is not declared in $VARS_REL" >&2
}

_declared() {
  case "$DECLARED" in *" $1 "*) return 0 ;; esac
  return 1
}

# ── Arguments ────────────────────────────────────────────────────────────────
if [ $# -ne 1 ]; then
  echo "usage: contracts.sh <provider-dir>   e.g. modules/aws" >&2
  exit 2
fi

arg=${1#"$REPO_ROOT/"}
arg=${arg%/}
PROVIDER_DIR="$REPO_ROOT/$arg"
provider=${arg##*/}

if [ ! -d "$PROVIDER_DIR" ]; then
  echo "contracts: no such dir: $arg" >&2
  exit 2
fi

case " $SKIP_PROVIDERS " in
  *" $provider "*)
    echo "== contracts $arg"
    echo "   (skipped: $provider has no tfvars accessors)"
    exit 0
    ;;
esac

VARS="$PROVIDER_DIR/infra/variables.tf"
VARS_REL="$arg/infra/variables.tf"
if [ ! -f "$VARS" ]; then
  echo "contracts: $VARS_REL is missing, so every name would read as undeclared." >&2
  echo "The provider directory was renamed, or its root module moved." >&2
  exit 2
fi

# Space-delimited membership rather than an associative array: bash 3.2.
DECLARED=" $(grep -hoE '^variable[[:space:]]+"[^"]+"' "$VARS" \
  | sed -E 's/^variable[[:space:]]+"//; s/"$//' | sort -u | tr '\n' ' ')"
declared_n=$(echo "$DECLARED" | wc -w | tr -d ' ')

echo "== contracts $arg"
echo "   $declared_n variables declared in $VARS_REL"

# Tracked scripts only, so an ignored tree (.terraform/, a worktree) drops out
# without an exclude list.
scripts=$(cd "$REPO_ROOT" && git ls-files "$arg/*.sh")
if [ -z "$scripts" ]; then
  echo "contracts: no tracked *.sh under $arg, so this run would have checked" >&2
  echo "nothing. The directory was renamed, or its scripts moved." >&2
  exit 2
fi

# ── Check 5: the accessor registry is still complete ─────────────────────────
# Runs first: every other check reads through this list, so an unregistered
# helper has to fail loudly rather than shrink the scan.
COMMON="$PROVIDER_DIR/infra/scripts/_common.sh"
if [ ! -f "$COMMON" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh is missing." >&2
  exit 2
fi
unregistered=""
for fn in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$COMMON" | sed 's/()//' | grep tfvar); do
  case " $ACCESSORS " in *" $fn "*) ;; *) unregistered="$unregistered $fn" ;; esac
done
if [ -n "$unregistered" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh defines tfvars accessor(s)$unregistered" >&2
  echo "that contracts.sh does not know about. Add them to ACCESSORS, or the keys" >&2
  echo "read through them go unchecked." >&2
  exit 2
fi

# ── Accessor set for this provider ───────────────────────────────────────────
wrappers=""
for f in $scripts; do
  for w in $(_wrapper_defs "$REPO_ROOT/$f"); do
    case " $wrappers " in *" $w "*) ;; *) wrappers="$wrappers $w" ;; esac
  done
done
for w in $WRAPPERS_KNOWN; do
  case " $wrappers " in
    *" $w "*) ;;
    *) echo "contracts: $arg defines no $w wrapper; the alias was renamed or removed." >&2
       exit 2 ;;
  esac
done
all_accessors="$ACCESSORS$wrappers"
echo "   accessors: $ACCESSORS (+ wrapper$wrappers)"

# ── Check 1: keys read through an accessor ───────────────────────────────────
read_keys=""
for f in $scripts; do
  while IFS="$TAB" read -r kind lineno a b; do
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      dyn)
        notes="$notes$f:$lineno  $a
"
        ;;
      key|file)
        # The file argument decides which root's variables the key belongs to.
        # Every current use resolves to a bare *.tfvars name, which _common.sh
        # resolves against INFRA_DIR -- the same root as variables.tf. An
        # absolute path or one that climbs out belongs to some other root and
        # cannot be checked here.
        if [ "$kind" = file ]; then
          case "$b" in
            */*|"")
              echo "contracts: $f:$lineno reads $a from \"$b\", which is not a bare" >&2
              echo "tfvars name under $arg/infra, so its root module is unknown." >&2
              exit 2
              ;;
            *.tfvars) ;;
            *)
              echo "contracts: $f:$lineno reads $a from \"$b\", which is not a tfvars file." >&2
              exit 2
              ;;
          esac
        fi
        case " $read_keys " in *" $a "*) ;; *) read_keys="$read_keys $a" ;; esac
        _declared "$a" || _report "$f" "$lineno" "read key" "$a"
        ;;
    esac
  done <<EOF
$(_accessor_calls "$all_accessors" "$REPO_ROOT/$f")
EOF
done
echo "   $(echo "$read_keys" | wc -w | tr -d ' ') keys read through an accessor"

# ── Check 2: keys written into a tfvars file ─────────────────────────────────
write_keys=""
for f in $scripts; do
  hd=$(_tfvars_heredocs "$REPO_ROOT/$f") || {
    echo "contracts: $f: heredoc scan failed, see above" >&2; exit 2; }
  hd_keys=""
  if [ -n "$hd" ]; then
    # Piped separately rather than folded into one pipeline with the sort
    # below: a pipeline reports only its last command's status, which would
    # swallow the unbalanced-braces exit.
    hd_keys=$(printf '%s\n' "$hd" | _hcl_keys) || {
      echo "contracts: $f: heredoc body unbalanced, see above" >&2; exit 2; }
  fi
  qw=""
  if _writes_tfvars "$REPO_ROOT/$f"; then
    qw=$(_quoted_tfvars_writes "$REPO_ROOT/$f")
  fi
  emitted=$(printf '%s\n%s\n' "$hd_keys" "$qw" | grep -v '^$' | sort -u -t"$TAB" -k2)
  [ -n "$emitted" ] || continue
  while IFS="$TAB" read -r lineno key; do
    [ -n "${key:-}" ] || continue
    case " $write_keys " in *" $key "*) ;; *) write_keys="$write_keys $key" ;; esac
    _declared "$key" || _report "$f" "$lineno" "generated tfvars key" "$key"
  done <<EOF
$emitted
EOF
done
echo "   $(echo "$write_keys" | wc -w | tr -d ' ') keys written into a tfvars file"

# ── Check 3: keys in terraform.tfvars.example ────────────────────────────────
EXAMPLE="$PROVIDER_DIR/infra/terraform.tfvars.example"
EXAMPLE_REL="$arg/infra/terraform.tfvars.example"
if [ ! -f "$EXAMPLE" ]; then
  echo "contracts: $EXAMPLE_REL is missing." >&2
  exit 2
fi
example_keys=$(_numbered "$EXAMPLE" | _hcl_keys) || {
  echo "contracts: $EXAMPLE_REL: unbalanced, see above" >&2; exit 2; }
example_n=0
while IFS="$TAB" read -r lineno key; do
  [ -n "${key:-}" ] || continue
  example_n=$((example_n + 1))
  _declared "$key" || _report "$EXAMPLE_REL" "$lineno" "example key" "$key"
done <<EOF
$(printf '%s\n' "$example_keys" | sort -u -t"$TAB" -k2)
EOF
echo "   $example_n keys in $EXAMPLE_REL"

# ── Check 4: TF_VAR_ exports ─────────────────────────────────────────────────
# The silent kind: terraform ignores an undeclared TF_VAR_* with no output at
# all. This is #140 -- setup-env.sh exported three secrets the GCP root did not
# declare -- run automatically.
SETUP="$PROVIDER_DIR/infra/scripts/setup-env.sh"
SETUP_REL="$arg/infra/scripts/setup-env.sh"
if [ ! -f "$SETUP" ]; then
  echo "contracts: $SETUP_REL is missing." >&2
  exit 2
fi
tf_var_n=0
while IFS=: read -r lineno name; do
  [ -n "${name:-}" ] || continue
  tf_var_n=$((tf_var_n + 1))
  _declared "${name#TF_VAR_}" || _report "$SETUP_REL" "$lineno" "TF_VAR_ export" "${name#TF_VAR_}"
done <<EOF
$(grep -noE 'TF_VAR_[A-Za-z0-9_]+' "$SETUP" | sort -u -t: -k2 | sort -n -t:)
EOF
echo "   $tf_var_n TF_VAR_ exports in $SETUP_REL"

# ── Runtime-built keys ───────────────────────────────────────────────────────
# A static check cannot see a key assembled at runtime, so name the call sites
# rather than pass over them. gcp/infra/scripts/status.sh builds enable_${addon}
# from a literal loop over three add-ons; all six resolved names are declared
# today, but nothing here proves that.
if [ -n "$notes" ]; then
  echo "   note: keys built at runtime, not checked:"
  printf '%s' "$notes" | sed 's/^/     /'
fi

if [ "$findings" -gt 0 ]; then
  echo "" >&2
  echo "contracts: $findings undeclared name(s) in $arg" >&2
  exit 1
fi
exit 0
