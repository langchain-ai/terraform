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
# unbalanced braces, an accessor helper this script can neither follow nor
# name).
#
# A silent under-report is the failure mode to design against here: "no
# findings" from a scan that skipped the content is worse than a false
# positive, because it reads as confidence. So wherever a pattern could stop
# matching -- a heredoc whose keys stopped being extracted, an accessor helper
# that grew a second line, a provider directory that got renamed -- the answer
# is exit 2, not an empty result.
#
# Out of scope: the operator's own infra/terraform.tfvars. It is gitignored, so
# CI never sees it, and a stray key there is precisely the warning-and-exit-0
# case above -- an aks_deletion_protection carried across from GCP's
# gke_deletion_protection has no Azure counterpart and sits inert. Only the
# checked-in example and the generators that write tfvars are covered;
# documentation is the mitigation for a hand-edited file.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

# Primitive accessors: the helpers in _common.sh that read a tfvars file
# themselves. Check 5 asserts this list still covers every such helper, so a
# new primitive fails the run until it is registered rather than passing having
# silently read nothing through it. Helpers that merely forward to one of these
# are discovered per provider instead (see _func_classes).
ACCESSORS="_parse_tfvar _parse_tfvar_quoted _tfvar_is_true"
# Wrappers are discovered, but _read_tfvar is named here too so a provider that
# drops its status.sh alias does not quietly change what gets scanned.
WRAPPERS_KNOWN="_read_tfvar"
# Providers with no tfvars accessors at all. Skipped by name, not by an empty
# result: an empty result is also what a renamed directory or a broken scan
# looks like, and those must fail. ocp's scripts read zero tfvars keys; byoc is
# a standalone IAM root with no infra/ tree.
SKIP_PROVIDERS="byoc ocp"
# Records are tab-separated; bash 3.2 has no dollar-quoted \t.
TAB=$(printf '\t')

# ── Shared awk pieces ────────────────────────────────────────────────────────
# Concatenated into the awk programs below rather than repeated in each. Both
# grew out of review findings where two collectors disagreed about the same
# line, which is exactly the drift that turns into a silent under-report.
#
# No literal single quote appears in any awk source here: these programs are
# shell single-quoted, so the character is spelled sprintf("%c", 39).
AWK_LIB='
function _sq() { return sprintf("%c", 39) }

# s with any trailing comment removed. A # inside a quoted span is part of a
# value, not a comment, so the scan tracks quote state instead of cutting at
# the first #. A whole-line comment comes back empty.
function _decomment(s,   i, c, q, out, sq) {
  sq = _sq(); q = ""; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != sq && c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
    if (q == "") {
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|(]/)) break
      if (c == "\"" || c == sq) q = c
    } else if (c == q) q = ""
    out = out c
  }
  return out
}

# The quote character still open at the end of s, or "" when balanced. A shell
# string that stays open carries its context onto the next line, which is how a
# multi-line argument such as _write_override "a = 1\nb = 2" is read as one
# write rather than as one write and one unrelated line.
function _qstate(s,   i, c, q, sq) {
  sq = _sq(); q = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != sq && c == "\\") { i++; continue }
    if (q == "") { if (c == "\"" || c == sq) q = c }
    else if (c == q) q = ""
  }
  return q
}

# _qstate carried across lines: the state s leaves behind, given the state q it
# started in. A comment closes the state rather than feeding it, which is the
# whole reason this is not just _qstate over the concatenated lines. One
# apostrophe in one prose comment leaves that version open for the rest of the
# file, and every tfvars write below it drops out with no output and exit 0.
function _qnext(q, s,   i, c, sq) {
  sq = _sq()
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (q != sq && c == "\\") { i++; continue }
    if (q == "") {
      if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;&|(]/)) return ""
      if (c == "\"" || c == sq) q = c
    } else if (c == q) q = ""
  }
  return q
}

# A real heredoc start on s. Fills o["delim"], o["dash"], o["target"] and
# returns 1, or returns 0.
#
# Both guards earn their place. A <<DELIM inside a comment or inside a quoted
# string is text, and treating it as a start is the worst thing this script can
# do: a phantom whose target is not tfvars sets want=0, and its body then
# swallows the next real tfvars heredoc and drops those keys with no output and
# exit 0. Inserting "# ...  kubectl apply -f - <<EOF" above azure setup-env.sh
# secrets heredoc used to do exactly that.
function _hd_start(s, o,   sq, re, d, t, pre) {
  s = _decomment(s)
  if (s ~ /<<</) return 0
  sq = _sq()
  re = "<<-?[ \t]*[\"" sq "]?[A-Za-z_][A-Za-z0-9_]*[\"" sq "]?[ \t]*$"
  if (!match(s, re)) return 0
  pre = substr(s, 1, RSTART - 1)
  if (_qstate(pre) != "") return 0
  d = substr(s, RSTART, RLENGTH)
  o["dash"] = (d ~ /^<<-/) ? 1 : 0
  sub(/^<<-?[ \t]*/, "", d); gsub("[\"" sq "]", "", d); sub(/[ \t]*$/, "", d)
  o["delim"] = d
  t = pre; sub(/^.*>[>]?[ \t]*/, "", t); gsub("[\"${}]", "", t)
  sub(/[ \t]+$/, "", t)
  o["target"] = t
  return 1
}

# Resolve a redirect target or file argument through one level of shell
# variable, so OUTPUT, SECRETS_FILE, TFVARS and OVERRIDE_FILE all land on the
# path they hold.
function _resolve(t, var,   sq) {
  sq = _sq()
  gsub("[\"" sq "]", "", t)
  gsub(/[${}]/, "", t)
  sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
  return (t in var) ? var[t] : t
}
'

# Assignment tracking. Anchored on an optional declaration keyword because the
# tfvars heredocs mostly live inside functions, where `local out="..."` is the
# likelier spelling than a bare assignment -- and an unresolved target means
# want stays 0 and the whole heredoc goes unchecked in silence.
#
# Guarded on _in_hd so a `key=value` line inside a heredoc body does not
# register as a shell assignment. Only _tfvars_heredocs sets that flag; in the
# other programs it is always unset, so the guard is free.
AWK_ASSIGN='
!_in_hd && $0 ~ /^[ \t]*(local|export|declare|readonly|typeset)?[ \t]*(-[A-Za-z]+[ \t]+)?[A-Za-z_][A-Za-z0-9_]*\+?=/ {
  _v = $0
  sub(/^[ \t]*/, "", _v)
  sub(/^(local|export|declare|readonly|typeset)[ \t]+/, "", _v)
  sub(/^-[A-Za-z]+[ \t]+/, "", _v)
  _app = (_v ~ /^[A-Za-z_][A-Za-z0-9_]*\+=/)
  sub(/\+?=.*/, "", _v)
  _val = $0; sub(/^[^=]*=/, "", _val); gsub(/"/, "", _val)
  if (_v != "") {
    if (_app) appended[_v] = 1
    else var[_v] = _val
  }
}

# An append can also sit mid-line behind a guard, which the anchored rule above
# does not see: quickstart.sh builds its whole security block as
# `[[ "$X" == true ]] && { SECURITY_BLOCK+="create_waf = true\n"; ... }`. Only
# the name is taken, and only to recognise the variable as an accumulator: a
# spurious entry there costs nothing, a missing one drops six keys.
!_in_hd {
  _rest = $0
  while (match(_rest, /(^|[ \t;&|{(])[A-Za-z_][A-Za-z0-9_]*\+=/)) {
    _a = substr(_rest, RSTART, RLENGTH); _rest = substr(_rest, RSTART + RLENGTH)
    sub(/^[^A-Za-z_]/, "", _a); sub(/\+=$/, "", _a)
    if (_a != "") appended[_a] = 1
  }
}
'

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
#
# An HCL heredoc value (key = <<-EOT ... EOT) is a legal multi-line string. The
# key is a root key, but the body is a value: without skipping it, a
# `helm_override = "x"` line inside one is reported as an undeclared variable
# and its braces move the depth.
#
# With -v nested=1 the sense inverts and only keys below depth 0 come out: the
# fields inside a block value. Those are not root variables and are not
# declared anywhere, but a script can still read one, so check 1 needs to tell
# them apart from a name that exists nowhere.
_hcl_keys() {
  awk -F'\t' -v nested="${1:-}" '
    { n = $1; s = $0; sub(/^[0-9]+\t/, "", s) }
    hd != "" {
      t = s; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == hd) hd = ""
      next
    }
    {
      gsub(/\\"/, "", s); gsub(/"[^"]*"/, "", s)
      sub(/#.*/, "", s); sub(/\/\/.*/, "", s)
      if (s ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=[^=]/) {
        k = s; sub(/^[ \t]*/, "", k); sub(/[ \t]*=.*/, "", k)
        if (nested ? depth > 0 : depth == 0) print n "\t" k
        if (s ~ /=[ \t]*<<-?[A-Za-z_]/) {
          hd = s; sub(/^.*<<-?/, "", hd); sub(/[ \t].*/, "", hd)
          next
        }
      }
      depth += gsub(/[{[]/, "", s) - gsub(/[}\]]/, "", s)
    }
    END {
      if (depth != 0) {
        print "brace depth " depth " at EOF, key set would be partial" > "/dev/stderr"
        exit 3
      }
      if (hd != "") {
        print "HCL heredoc <<" hd " never closed, key set would be partial" > "/dev/stderr"
        exit 3
      }
    }
  '
}

# Numbered-line view of a whole file, the input _hcl_keys expects.
_numbered() { awk '{ print NR "\t" $0 }' "$1"; }

# ── Collectors ───────────────────────────────────────────────────────────────
# Bodies of every heredoc whose redirect target resolves to a *.tfvars path, as
# numbered lines, followed by one "COUNT\t<n>" record giving how many such
# heredocs were opened. The caller needs the count to tell "this file writes no
# tfvars" apart from "the extraction broke", which look identical otherwise.
#
# The delimiter is read off the redirect line rather than hardcoded: quickstart.sh
# uses TFVARS and azure's setup-env.sh uses EOF. The target is resolved through
# one level of shell variable, which is also what keeps a heredoc writing
# something other than tfvars out.
_tfvars_heredocs() {
  awk "$AWK_LIB$AWK_ASSIGN"'
    _in_hd {
      t = $0; if (dash) sub(/^\t+/, "", t)
      if (t == delim) { _in_hd = 0; next }
      if (want) print NR "\t" $0
      next
    }
    _hd_start($0, o) {
      delim = o["delim"]; dash = o["dash"]
      want = (_resolve(o["target"], var) ~ /\.tfvars$/)
      if (want) opened++
      _in_hd = 1
      next
    }
    END {
      if (_in_hd) {
        print "unterminated heredoc <<" delim > "/dev/stderr"
        exit 3
      }
      print "COUNT\t" opened + 0
    }
  ' "$1"
}

# Function definitions in one script, classified by what the body does:
#   wrapper <name>   forwards the function's own $1 to a known accessor
#   writer  <name>   redirects into a path that resolves to *.tfvars
#
# One walker for both, since both need the same thing: the head in all four
# spellings (name(), name (), function name, function name()) and the body up to
# its close.
#
# Wrappers have to be followed or check 1 under-reports -- azure reads 21 keys
# instead of 36 without _read_tfvar. Matching only the one-line
# `_read_tfvar() { _parse_tfvar "$1"; }` form is not enough: `local key="$1"` on
# one line and `_tfvar_is_true "$key"` on the next is the same forward, which is
# how aws's _read_gateway_flag is written, and a four-line helper whose name
# says nothing about tfvars used to slip past every check here.
#
# The body ends at a close brace in column 0, the convention in all 203 function
# definitions under modules/. Brace counting would be the general answer, but
# ${VAR} and a brace inside a string both feed it noise. Heredoc bodies are
# skipped while walking, because a JSON heredoc indents its own } to column 0
# and would otherwise end the function early.
_func_classes() {
  awk -v accs="$1" "$AWK_LIB$AWK_ASSIGN"'
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    _in_hd {
      t = $0; if (dash) sub(/^\t+/, "", t)
      if (t == delim) _in_hd = 0
      next
    }
    _hd_start($0, o) { delim = o["delim"]; dash = o["dash"]; _in_hd = 1; next }
    fname == "" && match($0, /^[ \t]*(function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))[ \t]*\{/) {
      fname = substr($0, RSTART, RLENGTH)
      sub(/^[ \t]*/, "", fname); sub(/^function[ \t]+/, "", fname)
      sub(/[ \t]*(\(\))?[ \t]*\{$/, "", fname)
      delete argv1
      # A one-line definition opens and closes on the head line, so classify it
      # here and clear straight away.
      if ($0 ~ /\}[ \t]*$/) { _classify($0, fname, acc, argv1, var); fname = "" }
      next
    }
    fname != "" {
      # `local key="$1"` makes $key another spelling of $1 for the rest of the
      # body, and every multi-line wrapper in the tree is written that way.
      # Not anchored to end of line: aws _read_gateway_flag declares its second
      # local on the same line, as `local key="$1" val`.
      if (match($0, /[A-Za-z_][A-Za-z0-9_]*=[ \t]*"?\$\{?1\}?"?([ \t]|$)/)) {
        a1 = substr($0, RSTART, RLENGTH); sub(/=.*/, "", a1); argv1[a1] = 1
      }
      _classify($0, fname, acc, argv1, var)
      if ($0 ~ /^\}/) fname = ""
    }
    function _classify(line, fn, acc, argv1, var,   s, i, m, tgt, tok, nt, t) {
      s = _decomment(line)
      # Accessor called with the function own argument, directly or by alias.
      nt = split(s, t, /[ \t]+/)
      for (i = 1; i <= nt; i++) {
        tok = t[i]; sub(/^.*[^A-Za-z0-9_]/, "", tok)
        if (!(tok in acc) || i == nt) continue
        m = t[i+1]; gsub("[\"" _sq() "]", "", m); sub(/[);&|].*$/, "", m)
        gsub(/[${}]/, "", m)
        if (m == "1" || (m in argv1)) print "wrapper " fn
      }
      # A function that names a tfvars file in its own body reads or writes one
      # directly, which is what makes it a primitive rather than a forwarder.
      if (s ~ /\.tfvars/) print "touch " fn
      # Redirect into a tfvars path makes this function a tfvars writer, so its
      # callers string arguments are tfvars content (test-permutations.sh
      # _write_override).
      if (match(s, />>?[ \t]*[^ \t;&|<>]+/)) {
        tgt = substr(s, RSTART, RLENGTH); sub(/^>>?[ \t]*/, "", tgt)
        if (_resolve(tgt, var) ~ /\.tfvars$/) print "writer " fn
      }
    }
  ' "$2"
}

# tfvars assignments emitted from shell rather than from a heredoc, as
# "<lineno>\t<key>": tls.sh seds acm_certificate_arn back into terraform.tfvars,
# the quickstart scripts echo optional keys one line at a time and accumulate a
# security block in a variable, and test-permutations.sh hands a multi-line
# block to _write_override.
#
# Gated per line, not per file. A file-level gate reads every `key = value`
# string in any script that writes tfvars somewhere, so an
# `echo "bucket = \"x\"" > backend.tf` in the same script reports bucket as an
# undeclared variable, and an error message that quotes tfvars syntax
# (tls.sh:47) counts as a write. The line has to actually land in a tfvars file:
# a redirect resolving to *.tfvars, a sed -i naming one, a call to a function
# whose own body writes one, or an append to a variable that is later written
# into one. A quoted string left open carries the gate onto its continuation
# lines.
#
# The file is read three times. An accumulator is appended to before the
# redirect that reveals where it goes -- quickstart.sh builds SECURITY_BLOCK at
# 931 and writes it at 945 -- so one pass cannot know it is a tfvars sink. Two
# would do for that ordering and quietly drop six keys for the other one, so the
# appends, the sinks and the keys each get their own pass.
_quoted_tfvars_writes() {
  awk -v writers="$1" "$AWK_LIB$AWK_ASSIGN"'
    BEGIN { n = split(writers, w, " "); for (i = 1; i <= n; i++) wr[w[i]] = 1 }
    function _dest(line, var, wr,   s, i, tok, nt, t, tgt, hit) {
      s = _decomment(line)
      hit = 0
      if (match(s, />>?[ \t]*[^ \t;&|<>]+/)) {
        tgt = substr(s, RSTART, RLENGTH); sub(/^>>?[ \t]*/, "", tgt)
        # A redirect that goes anywhere else settles it: this line is not a
        # tfvars write, whatever else it mentions.
        return (_resolve(tgt, var) ~ /\.tfvars$/) ? 1 : 0
      }
      nt = split(s, t, /[ \t]+/)
      for (i = 1; i <= nt; i++) {
        # Both ends of the token. A call is the identifier at the end of
        # `val=$(_write_override`, and an append is the one at the start of
        # `SECURITY_BLOCK+="alb_scheme = ...`; taking only the trailing run
        # reads that second one as alb_scheme and never finds the sink.
        tok = t[i]; sub(/^.*[^A-Za-z0-9_]/, "", tok)
        if (tok in wr || tok in sink) hit = 1
        tok = t[i]; sub(/[^A-Za-z0-9_].*$/, "", tok)
        if (tok in wr || tok in sink) hit = 1
      }
      if (s ~ /(^|[ \t;&|(])sed([ \t]+-[A-Za-z.]+)*[ \t]/) {
        for (i = 1; i <= nt; i++)
          if (_resolve(t[i], var) ~ /\.tfvars$/) hit = 1
      }
      return hit
    }
    FNR == 1 { pass++ }
    # Pass 1 is the shared assignment rule above, collecting var and appended.
    pass == 1 { next }
    # Pass 2: which of those accumulators end up inside a tfvars file.
    pass == 2 {
      s = _decomment($0)
      if (match(s, />>?[ \t]*[^ \t;&|<>]+/)) {
        tgt = substr(s, RSTART, RLENGTH); sub(/^>>?[ \t]*/, "", tgt)
        if (_resolve(tgt, var) ~ /\.tfvars$/) {
          rest = s
          while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
            v = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
            gsub(/[${}]/, "", v)
            if (v in appended) sink[v] = 1
          }
        }
      }
      next
    }
    {
      if (open == "") gate = _dest($0, var, wr)
      if (gate) {
        s = $0
        while (match(s, /(^|[^A-Za-z0-9_.\-])[a-z][a-z0-9_]*[ \t]*=[ \t]*[^ \t=]/)) {
          k = substr(s, RSTART, RLENGTH)
          s = substr(s, RSTART + RLENGTH)
          sub(/^[^a-z]/, "", k); sub(/[ \t]*=.*/, "", k)
          print NR "\t" k
        }
      }
      open = _qnext(open, $0)
      if (open == "") gate = 0
    }
  ' "$2" "$2" "$2"
}

# Accessor call sites. Emits one tab-separated record per call:
#   key   <lineno>  <key>            a literal key, checkable
#   file  <lineno>  <key>  <file>    an accessor reading a named file
#   dyn   <lineno>  <text>           the key is built at runtime, not checkable
#
# Tokenized rather than pattern-matched on the whole call, because all 26
# _read_tfvar call sites pass the key bare and requiring quotes undercounts
# azure by 15 keys. A trailing identifier run is what identifies the accessor,
# so `val=$(_parse_tfvar` matches and `_read_gateway_flag` does not.
#
# An argument of exactly "$1" is a definition forwarding its own argument, not a
# read, so it is neither checked nor reported. The same goes for a variable the
# file assigned from "$1": aws _read_gateway_flag reads through $key, and
# calling that a runtime-built key tells the operator to go look at a line whose
# key is perfectly static one call site away.
#
# _parse_tfvar_quoted takes an optional second argument naming the file, so the
# token after the key is only a filename when it resolves to one. Treating
# whatever followed as a filename regardless turned the one-argument form --
# `_parse_tfvar_quoted "$key" 2>/dev/null` and every call that ends after the
# key -- into an exit 2 claiming the root module was unknown. A token holding a
# path that is not tfvars still comes through as a file record, because naming
# some other root is the case check 1 has to refuse rather than skip.
_accessor_calls() {
  awk -v accs="$1" "$AWK_LIB"'
    /^[ \t]*#/ { next }
    '"$AWK_ASSIGN"'
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    # $1 aliases are per function, not per file. Scoping them to the file marks
    # "key" an alias for the whole of _common.sh -- _parse_tfvar declares it
    # that way on its first line -- and then azure _values_input_stamp, which
    # loops "key" over a list, stops being reported as a runtime-built read.
    /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*(\(\))?[ \t]*\{/ || /^\}/ {
      delete argv1
    }
    match($0, /[A-Za-z_][A-Za-z0-9_]*=[ \t]*"?\$\{?1\}?"?([ \t]|$)/) {
      a1 = substr($0, RSTART, RLENGTH); sub(/=.*/, "", a1); argv1[a1] = 1
    }
    {
      n2 = split($0, t, /[ \t]+/)
      for (i = 1; i <= n2; i++) {
        tok = t[i]
        if (tok ~ /\(\)$/) continue
        sub(/^.*[^A-Za-z0-9_]/, "", tok)
        if (!(tok in acc)) continue
        arg = (i < n2) ? t[i+1] : ""
        gsub("[\"" _sq() "]", "", arg); sub(/[);&|].*$/, "", arg)
        if (arg == "$1" || arg == "${1}") continue
        bare = arg; gsub(/[${}]/, "", bare)
        if (bare in argv1) continue
        if (arg ~ /\$/) {
          src = $0; sub(/^[ \t]+/, "", src); gsub(/\t/, " ", src)
          print "dyn\t" NR "\t" src; continue
        }
        if (arg !~ /^[A-Za-z_][A-Za-z0-9_]*$/) continue
        f = ""
        if (i + 2 <= n2) {
          cand = t[i+2]
          sub(/[);&|].*$/, "", cand)
          # A redirection is not an argument. `_parse_tfvar_quoted "$k"
          # 2>/dev/null` used to resolve to "2>/dev/null" and fail the run
          # claiming that path was an unknown root module.
          if (cand !~ /[<>]/) {
            r = _resolve(cand, var)
            if (r ~ /\.tfvars$/ || r ~ /\//) f = r
          }
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

# Fields inside a block value in the checked-in example -- instance_types and
# friends inside eks_node_groups. Not root variables, so nothing declares them,
# but _parse_tfvar anchors its grep loosely enough to reach one and
# aws/quickstart.sh reads instance_types that way on purpose. Reporting those as
# undeclared is wrong and dropping them silently is worse, so they are noted.
EXAMPLE="$PROVIDER_DIR/infra/terraform.tfvars.example"
EXAMPLE_REL="$arg/infra/terraform.tfvars.example"
if [ ! -f "$EXAMPLE" ]; then
  echo "contracts: $EXAMPLE_REL is missing." >&2
  exit 2
fi
NESTED=" $(_numbered "$EXAMPLE" | _hcl_keys nested | awk -F"$TAB" '{ print $2 }' \
  | sort -u | tr '\n' ' ')"

# ── Check 5: the accessor registry is still complete ─────────────────────────
# Runs first: every other check reads through this list, so an unregistered
# helper has to fail loudly rather than shrink the scan.
#
# Behavior, not name. Matching function names against "tfvar" only catches a
# primitive that happens to be called one: _read_setting() { _parse_tfvar "$1"
# || echo "$2"; } is a tfvars accessor by any useful definition and the name
# rule passes it in silence, so every key read through it goes unchecked. What
# actually distinguishes a primitive is that its body names a tfvars file.
COMMON="$PROVIDER_DIR/infra/scripts/_common.sh"
if [ ! -f "$COMMON" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh is missing." >&2
  exit 2
fi
unregistered=""
for fn in $(_func_classes "$ACCESSORS" "$COMMON" | awk '$1 == "touch" { print $2 }' | sort -u); do
  case " $ACCESSORS " in *" $fn "*) ;; *) unregistered="$unregistered $fn" ;; esac
done
if [ -n "$unregistered" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh defines$unregistered, which read a" >&2
  echo "tfvars file directly but are not in ACCESSORS. Register them there, or every" >&2
  echo "key read through them goes unchecked." >&2
  exit 2
fi

# ── Accessors and writers for this provider ──────────────────────────────────
# Two things are discovered per provider rather than listed: helpers that
# forward to an accessor, and functions that write a tfvars file.
#
# Wrappers are followed to a fixpoint, because a helper forwarding to a wrapper
# is itself a wrapper and one pass stops at the first hop. Following them is not
# cosmetic: azure reads 21 keys instead of 36 without _read_tfvar, and every
# unfollowed hop is fifteen keys nothing checks.
wrappers=""
writers=""
settled=0
pass=0
while [ "$pass" -lt 5 ]; do
  pass=$((pass + 1))
  grew=0
  for f in $scripts; do
    while read -r class name; do
      [ -n "${name:-}" ] || continue
      case "$class" in
        wrapper)
          case " $ACCESSORS$wrappers " in
            *" $name "*) ;;
            *) wrappers="$wrappers $name"; grew=1 ;;
          esac
          ;;
        writer)
          case " $writers " in *" $name "*) ;; *) writers="$writers $name" ;; esac
          ;;
      esac
    done <<EOF
$(_func_classes "$ACCESSORS$wrappers" "$REPO_ROOT/$f")
EOF
  done
  if [ "$grew" -eq 0 ]; then settled=1; break; fi
done
if [ "$settled" -eq 0 ]; then
  echo "contracts: wrapper discovery did not settle in 5 passes over $arg." >&2
  echo "Either the forwarding chain is deeper than that or it is circular; the" >&2
  echo "accessor set is incomplete either way." >&2
  exit 2
fi

for w in $WRAPPERS_KNOWN; do
  case " $wrappers " in
    *" $w "*) ;;
    *) echo "contracts: $arg defines no $w wrapper; the alias was renamed or removed." >&2
       exit 2 ;;
  esac
done
all_accessors="$ACCESSORS$wrappers"

# The name rule, kept for what the behavior rule cannot see: a helper named for
# tfvars that neither reads a file itself nor forwards in a shape this script
# can follow. It reads something, and nothing above found out what.
unfollowed=""
for fn in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$COMMON" | sed 's/()//' | grep tfvar); do
  case " $all_accessors " in *" $fn "*) ;; *) unfollowed="$unfollowed $fn" ;; esac
done
if [ -n "$unfollowed" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh defines$unfollowed, named for tfvars" >&2
  echo "but neither registered in ACCESSORS nor recognisable as a forwarder. Add it," >&2
  echo "or the keys read through it go unchecked." >&2
  exit 2
fi

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
        if ! _declared "$a"; then
          case "$NESTED" in
            *" $a "*)
              notes="$notes$f:$lineno  reads $a, a field inside a block value, not a root variable
"
              ;;
            *) _report "$f" "$lineno" "read key" "$a" ;;
          esac
        fi
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
  # The trailing COUNT record says how many tfvars heredocs were opened, which
  # is the only way to tell "this file writes none" from "the extraction
  # broke". Both produce an empty key set, and one of them is a clean bill of
  # health for content nothing looked at.
  opened=$(printf '%s\n' "$hd" | awk -F"$TAB" '$1 == "COUNT" { print $2 }')
  hd=$(printf '%s\n' "$hd" | grep -v "^COUNT$TAB")
  # Body lines that look like assignments. A tfvars heredoc whose body is one
  # "$content" expansion (test-permutations.sh _write_override) legitimately
  # yields no keys; one full of key = value lines that yields none means the
  # extractor stopped matching.
  hd_assigns=$(printf '%s\n' "$hd" \
    | grep -cE "^[0-9]+${TAB}[ ${TAB}]*[A-Za-z_][A-Za-z0-9_-]*[ ${TAB}]*=[^=]" | tr -d ' ')
  hd_keys=""
  if [ -n "$hd" ]; then
    # Piped separately rather than folded into one pipeline with the sort
    # below: a pipeline reports only its last command's status, which would
    # swallow the unbalanced-braces exit.
    hd_keys=$(printf '%s\n' "$hd" | _hcl_keys) || {
      echo "contracts: $f: heredoc body unbalanced, see above" >&2; exit 2; }
  fi
  if [ "${opened:-0}" -gt 0 ] && [ "${hd_assigns:-0}" -gt 0 ] && [ -z "$hd_keys" ]; then
    echo "contracts: $f opens $opened heredoc(s) into a tfvars file whose bodies hold" >&2
    echo "$hd_assigns assignment(s), and no key came out of any of them. Reporting that" >&2
    echo "as clean would be a silent pass over generated content; fix the extractor." >&2
    exit 2
  fi
  qw=$(_quoted_tfvars_writes "$writers" "$REPO_ROOT/$f")
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
#
# Comments are stripped first. Most of these names are not exported directly:
# they are string arguments to _sm_secret and _ssm_secret, which export
# indirectly, so the scan cannot be narrowed to `export TF_VAR_x=` without
# dropping ten of aws's sixteen. What it can do is not read a name out of a
# commented-out line, which otherwise reports a variable that was deleted along
# with the export that used it.
SETUP="$PROVIDER_DIR/infra/scripts/setup-env.sh"
SETUP_REL="$arg/infra/scripts/setup-env.sh"
if [ ! -f "$SETUP" ]; then
  echo "contracts: $SETUP_REL is missing." >&2
  exit 2
fi
tf_var_n=0
while IFS="$TAB" read -r lineno name; do
  [ -n "${name:-}" ] || continue
  tf_var_n=$((tf_var_n + 1))
  _declared "${name#TF_VAR_}" || _report "$SETUP_REL" "$lineno" "TF_VAR_ export" "${name#TF_VAR_}"
done <<EOF
$(awk "$AWK_LIB"'
  {
    s = _decomment($0)
    while (match(s, /TF_VAR_[A-Za-z0-9_]+/)) {
      nm = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      if (!(nm in seen)) { seen[nm] = 1; print NR "\t" nm }
    }
  }' "$SETUP")
EOF
echo "   $tf_var_n TF_VAR_ exports in $SETUP_REL"

# ── Reads that resolve to no root variable ───────────────────────────────────
# Two kinds, neither a finding and neither safe to drop. A key assembled at
# runtime is invisible to a static check: gcp/infra/scripts/status.sh builds
# enable_${addon} from a literal loop over three add-ons, and all six resolved
# names are declared today, but nothing here proves that. A field inside a block
# value is real and readable but is not a root variable, so variables.tf will
# never declare it.
#
# Naming the call sites is the point. Passing over them silently is the same
# under-report the exit 2 cases exist to prevent, one severity down.
if [ -n "$notes" ]; then
  echo "   note: reads not checked against $VARS_REL:"
  printf '%s' "$notes" | sed 's/^/     /'
fi

if [ "$findings" -gt 0 ]; then
  echo "" >&2
  echo "contracts: $findings undeclared name(s) in $arg" >&2
  exit 1
fi
exit 0
