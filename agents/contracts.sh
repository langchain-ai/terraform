#!/usr/bin/env bash
# Contract checks across the shell/HCL boundary, one provider per invocation:
#   bash agents/contracts.sh modules/aws
#
# terraform validate checks the HCL, shellcheck checks the shell; neither checks
# the names the two exchange. Miss a reader when renaming a variable and there is
# no error: the accessor falls back to its default, a generated tfvars key draws
# a warning and exit 0, and an undeclared TF_VAR_* is ignored silently (#140).
#
# Every check runs one direction: a name in use must be declared in that
# provider's infra/variables.tf. A declared variable nothing uses is not a
# finding, since most carry defaults and correctly appear in no example.
#
# Reads files only: no terraform, no cloud credentials, no state.
#
# Exit 0 clean, 1 findings, 2 the check could not run. Wherever a pattern could
# stop matching -- a heredoc that stopped extracting, an accessor that grew a
# second line, a renamed directory -- the answer is exit 2, never an empty
# result: "no findings" from a scan that skipped content reads as confidence.
#
# Out of scope: the operator's own gitignored infra/terraform.tfvars. CI never
# sees it, so a stray key there stays a warning nothing fails on.
set -u

unset CDPATH
REPO_ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)

# Primitive accessors: the _common.sh helpers that read a tfvars file
# themselves. Helpers that forward to one, and per-provider helpers that read a
# tfvars file of their own, are discovered rather than listed (see
# _func_classes); check 5 fails on one shaped so that nothing can follow it.
ACCESSORS="_parse_tfvar _parse_tfvar_quoted _tfvar_is_true"
# Named here too, so a provider dropping its status.sh alias fails loudly
# rather than quietly changing what gets scanned.
WRAPPERS_KNOWN="_read_tfvar"
# Providers with no tfvars accessors. Skipped by name, not by an empty result:
# a renamed directory or a broken scan looks the same and must fail.
SKIP_PROVIDERS="byoc ocp"
# Records are tab-separated; bash 3.2 has no dollar-quoted \t.
TAB=$(printf '\t')

# ── Shared awk pieces ────────────────────────────────────────────────────────
# Concatenated into the programs below so two collectors cannot drift apart on
# the same line. These programs are shell single-quoted, so a literal single
# quote is spelled sprintf("%c", 39).
AWK_LIB='
function _sq() { return sprintf("%c", 39) }

# s with any trailing comment removed. A # inside a quoted span is part of a
# value, so this tracks quote state rather than cutting at the first #.
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

# The quote character still open at the end of s, or "" when balanced. A string
# left open carries its context onto the next line, which is how a multi-line
# argument such as _write_override "a = 1\nb = 2" reads as one write.
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

# _qstate carried across lines. A comment closes the state rather than feeding
# it: one apostrophe in one prose comment would otherwise leave the state open
# for the rest of the file, dropping every tfvars write below it.
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
# A <<DELIM inside a comment or a quoted string is text. Treating one as a start
# is the worst case here: the phantom body swallows the next real tfvars heredoc
# and drops those keys with no output and exit 0.
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
# variable, so OUTPUT, SECRETS_FILE, TFVARS and OVERRIDE_FILE land on a path.
function _resolve(t, var,   sq) {
  sq = _sq()
  gsub("[\"" sq "]", "", t)
  gsub(/[${}]/, "", t)
  sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
  return (t in var) ? var[t] : t
}
'

# Assignment tracking. Declaration keywords are optional but matched, since the
# tfvars heredocs live inside functions where `local out="..."` is the likelier
# spelling -- and an unresolved target means the heredoc goes unchecked.
#
# _in_hd keeps a `key=value` line inside a heredoc body from registering as a
# shell assignment. Only _tfvars_heredocs sets it; elsewhere the guard is free.
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

# An append can also sit mid-line behind a guard: quickstart.sh builds its
# security block as `[[ ... ]] && { SECURITY_BLOCK+="create_waf = true\n"; }`.
# Only the name is taken, to recognise an accumulator; a spurious entry costs
# nothing, a missing one drops six keys.
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
# One depth-aware HCL key reader for every check that reads HCL, so the checks
# cannot drift apart on what counts as a key.
#
# In "<lineno>\t<text>", out "<lineno>\t<name>" per assignment at depth 0.
# Depth matters: a line grep on the aws example reports five keys that live
# inside eks_node_groups. Quoted spans come out first, so a brace or a # inside
# a string cannot move the depth or fake a comment. Depth that has not returned
# to 0 at EOF means the scrubbing lost track, and a partial key set silently
# under-reports, so that exits 3.
#
# An HCL heredoc value (key = <<-EOT ... EOT) is a legal multi-line string: the
# key is a root key but the body is a value, and a `helm_override = "x"` inside
# one would otherwise report as an undeclared variable.
#
# With -v nested=1 only keys below depth 0 come out -- the fields inside a block
# value, which check 1 needs to tell apart from a name that exists nowhere.
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
# Bodies of every heredoc whose redirect target resolves to *.tfvars, as
# numbered lines, then one "COUNT\t<n>" record. The caller needs the count to
# tell "this file writes no tfvars" from "the extraction broke".
#
# The delimiter is read off the redirect line rather than hardcoded (TFVARS in
# quickstart.sh, EOF in azure setup-env.sh), and the target resolved through one
# level of variable, which is also what keeps non-tfvars heredocs out.
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
#   reader  <name>   pulls a key out of a tfvars file itself
#   writer  <name>   redirects into a path that resolves to *.tfvars
#   uses    <name>   reaches a known accessor at all, in any shape
#
# Wrappers and readers are both followed, or check 1 under-reports: azure reads
# 21 keys instead of 36 without _read_tfvar, and 36 instead of 51 without the
# four readers its own scripts define. uses exempts a caller from check 5.
#
# A reader is a body that does all three of: run a text extractor, anchor a key
# lookup on the function's own $1, and name a tfvars file -- the file being $2
# in aws _tfvars_get. Per body rather than per line, since gcp _tfvar spreads
# the three over eight lines of an awk program. All three are needed: on two of
# them azure _read_values_stamp, which greps a comment stamp with the arguments
# the other way round, reads as an accessor and gets its file checked as a key.
#
# The body ends at a close brace indented like the definition. Column 0 alone
# loses every definition below azure/preflight.sh:186, which nests tfvar() in an
# else branch, and with it the _tfvar that file defines further down. Brace
# counting takes noise from ${VAR} and braces inside strings. Heredoc bodies are
# skipped while walking: a JSON heredoc indents its own } to column 0 and would
# end the function early. The heredoc head line is classified before it is
# skipped, since _write_override opens its heredoc on the same line as the
# redirect that makes it a writer.
_func_classes() {
  awk -v accs="$1" "$AWK_LIB$AWK_ASSIGN"'
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    _in_hd {
      t = $0; if (dash) sub(/^\t+/, "", t)
      if (t == delim) _in_hd = 0
      next
    }
    # A definition can open a heredoc on its own head line, so the head is read
    # as a definition before it is skipped as a heredoc start; the other order
    # leaves fname empty and the whole body unclassified.
    _hd_start($0, o) {
      if (fname == "" && _isdef($0, d)) {
        fname = d["name"]; ind = d["ind"]; delete argv1; delete argv2
      }
      if (fname != "") _classify($0, fname, acc, argv1, argv2, var)
      delim = o["delim"]; dash = o["dash"]; _in_hd = 1
      next
    }
    fname == "" && _isdef($0, d) {
      fname = d["name"]; ind = d["ind"]
      delete argv1; delete argv2
      # A one-line definition opens and closes on the head line.
      if ($0 ~ /\}[ \t]*$/) { _classify($0, fname, acc, argv1, argv2, var); fname = "" }
      next
    }
    fname != "" {
      # `local key="$1" file="$2"` makes $key and $file other spellings of the
      # arguments for the rest of the body.
      rest = $0
      while (match(rest, /[A-Za-z_][A-Za-z0-9_]*=[ \t]*"?\$\{?[12]\}?"?([ \t]|$)/)) {
        a1 = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        nm = a1; sub(/=.*/, "", nm)
        if (a1 ~ /\$\{?1\}?/) argv1[nm] = 1
        if (a1 ~ /\$\{?2\}?/) argv2[nm] = 1
      }
      _classify($0, fname, acc, argv1, argv2, var)
      close_at = $0; sub(/[^ \t].*$/, "", close_at)
      if ($0 ~ /^[ \t]*\}/ && length(close_at) == ind) fname = ""
    }
    # The name and indent of a function definition opening on this line.
    function _isdef(line, o,   f, pad) {
      if (!match(line, /^[ \t]*(function[ \t]+[A-Za-z_][A-Za-z0-9_]*([ \t]*\(\))?|[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\))[ \t]*\{/))
        return 0
      f = substr(line, RSTART, RLENGTH)
      pad = f; sub(/[^ \t].*$/, "", pad); o["ind"] = length(pad)
      sub(/^[ \t]*/, "", f); sub(/^function[ \t]+/, "", f)
      sub(/[ \t]*(\(\))?[ \t]*\{$/, "", f)
      o["name"] = f
      return 1
    }
    function _classify(line, fn, acc, argv1, argv2, var,   s, r, i, m, tgt, tok, nt, t) {
      s = _decomment(line)
      nt = split(s, t, /[ \t]+/)
      for (i = 1; i <= nt; i++) {
        tok = t[i]; sub(/^.*[^A-Za-z0-9_]/, "", tok)
        if (!(tok in acc)) continue
        print "uses " fn
        if (i == nt) continue
        # Called with the function own argument, directly or by alias.
        m = t[i+1]; gsub("[\"" _sq() "]", "", m); sub(/[);&|].*$/, "", m)
        gsub(/[${}]/, "", m)
        if (m == "1" || (m in argv1)) print "wrapper " fn
      }
      # A redirect into a tfvars path makes this a writer, so its callers pass
      # tfvars content (test-permutations.sh _write_override).
      if (match(s, />>?[ \t]*[^ \t;&|<>]+/)) {
        tgt = substr(s, RSTART, RLENGTH); sub(/^>>?[ \t]*/, "", tgt)
        if (_resolve(tgt, var) ~ /\.tfvars$/) print "writer " fn
      }
      # Redirect targets come off first: a grep whose output lands in a tfvars
      # file writes one, it does not read one.
      r = s; gsub(/>>?[ \t]*[^ \t;&|<>]+/, "", r)
      if (r ~ /(^|[^A-Za-z0-9_])(grep|sed|awk)([ \t]|$)/) rd[fn] = 1
      if (_key_pat(r, argv1)) kp[fn] = 1
      if (_file_arg(r, argv2, var)) fp[fn] = 1
    }
    # An anchored key lookup: ^ ... the function own first argument ... =. The
    # argument can be bare between the anchor and the =, since gcp _tfvar hands
    # it to awk as -v key="$1" and matches on the awk variable.
    function _key_pat(s, argv1,   v, re) {
      re = "1"
      for (v in argv1) re = re "|" v
      return (s ~ ("\\^[^=]*[^A-Za-z0-9_](" re ")[^A-Za-z0-9_][^=]*="))
    }
    # A token resolving to a tfvars path, or the function own second argument.
    function _file_arg(s, argv2, var,   i, nt, t, tok) {
      nt = split(s, t, /[ \t]+/)
      for (i = 1; i <= nt; i++) {
        tok = t[i]; sub(/[);&|].*$/, "", tok)
        if (_resolve(tok, var) ~ /\.tfvars$/) return 1
        gsub("[\"" _sq() "]", "", tok); gsub(/[${}]/, "", tok)
        if (tok == "2" || (tok in argv2)) return 1
      }
      return 0
    }
    END { for (f in rd) if (kp[f] && fp[f]) print "reader " f }
  ' "$2"
}

# tfvars assignments emitted from shell rather than from a heredoc, as
# "<lineno>\t<key>": tls.sh seds acm_certificate_arn back in, the quickstarts
# echo optional keys one at a time and accumulate a security block, and
# test-permutations.sh hands a multi-line block to _write_override.
#
# Gated per line, not per file. A file-level gate reads every `key = value`
# string in any script that writes tfvars somewhere, so an
# `echo "bucket = \"x\"" > backend.tf` reports bucket, and an error message
# quoting tfvars syntax (tls.sh:47) counts as a write. The line has to land in a
# tfvars file: a redirect resolving to *.tfvars, a sed -i naming one, a call to
# a writer, or an append to a variable later written into one. An open quoted
# string carries the gate onto its continuation lines.
#
# Three passes over the file, so line numbers are FNR: an accumulator is
# appended to before the redirect that reveals where it goes -- quickstart.sh
# builds SECURITY_BLOCK at 931 and writes it at 945 -- so appends, sinks and
# keys each get their own pass.
#
# Quote state is only carried while the gate is open. Carried unconditionally,
# one apostrophe outside a tfvars write freezes the gate for the rest of the
# file: aws/quickstart.sh:966 has "Let's Encrypt" inside a $(...), which blinds
# the 77 lines below it.
_quoted_tfvars_writes() {
  awk -v writers="$1" "$AWK_LIB$AWK_ASSIGN"'
    BEGIN { n = split(writers, w, " "); for (i = 1; i <= n; i++) wr[w[i]] = 1 }
    function _dest(line, var, wr,   s, i, tok, nt, t, tgt, hit) {
      s = _decomment(line)
      hit = 0
      if (match(s, />>?[ \t]*[^ \t;&|<>]+/)) {
        tgt = substr(s, RSTART, RLENGTH); sub(/^>>?[ \t]*/, "", tgt)
        # A redirect anywhere else settles it, whatever the line mentions.
        return (_resolve(tgt, var) ~ /\.tfvars$/) ? 1 : 0
      }
      nt = split(s, t, /[ \t]+/)
      for (i = 1; i <= nt; i++) {
        # Both ends of the token: a call is the identifier at the end of
        # `val=$(_write_override`, an append the one at the start of
        # `SECURITY_BLOCK+="alb_scheme = ...`.
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
      if (!gate) { open = ""; gate = _dest($0, var, wr) }
      if (gate) {
        s = $0
        while (match(s, /(^|[^A-Za-z0-9_.\-])[a-z][a-z0-9_]*[ \t]*=[ \t]*[^ \t=]/)) {
          k = substr(s, RSTART, RLENGTH)
          s = substr(s, RSTART + RLENGTH)
          sub(/^[^a-z]/, "", k); sub(/[ \t]*=.*/, "", k)
          print FNR "\t" k
        }
        open = _qnext(open, $0)
        if (open == "") gate = 0
      }
    }
  ' "$2" "$2" "$2"
}

# Accessor call sites, one tab-separated record per call:
#   key   <lineno>  <key>            a literal key, checkable
#   file  <lineno>  <key>  <file>    an accessor reading a named file
#   dyn   <lineno>  <text>           the key is built at runtime, not checkable
#
# Tokenized rather than matched on the whole call: all 26 _read_tfvar call sites
# pass the key bare, and requiring quotes undercounts azure by 15 keys. The
# accessor is the trailing identifier run, so `val=$(_parse_tfvar` matches and
# `_read_gateway_flag` does not.
#
# An argument of exactly "$1", or a variable the file assigned from it, is a
# definition forwarding its own argument rather than a read. Calling that a
# runtime-built key points the operator at a line whose key is static one call
# site away.
#
# _parse_tfvar_quoted takes an optional file argument, so the token after the
# key is a filename only when it resolves to one -- otherwise the one-argument
# form exits 2 claiming an unknown root module. A token holding a non-tfvars
# path still comes through, because naming another root has to be refused rather
# than skipped.
_accessor_calls() {
  awk -v accs="$1" "$AWK_LIB"'
    /^[ \t]*#/ { next }
    '"$AWK_ASSIGN"'
    BEGIN { n = split(accs, a, " "); for (i = 1; i <= n; i++) acc[a[i]] = 1 }
    # $1 aliases are per function, not per file: _parse_tfvar declares "key" on
    # its first line, which file scope would make an alias for all of
    # _common.sh, silencing the azure _values_input_stamp loop.
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
          # 2>/dev/null` used to resolve as an unknown root module.
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
# friends inside eks_node_groups. Nothing declares them, but _parse_tfvar
# anchors its grep loosely enough to reach one and aws/quickstart.sh reads
# instance_types that way on purpose. Reporting those as undeclared is wrong,
# and dropping them silently is worse, so they are noted.
EXAMPLE="$PROVIDER_DIR/infra/terraform.tfvars.example"
EXAMPLE_REL="$arg/infra/terraform.tfvars.example"
if [ ! -f "$EXAMPLE" ]; then
  echo "contracts: $EXAMPLE_REL is missing." >&2
  exit 2
fi
NESTED=" $(_numbered "$EXAMPLE" | _hcl_keys nested | awk -F"$TAB" '{ print $2 }' \
  | sort -u | tr '\n' ' ')"

COMMON="$PROVIDER_DIR/infra/scripts/_common.sh"
if [ ! -f "$COMMON" ]; then
  echo "contracts: $arg/infra/scripts/_common.sh is missing." >&2
  exit 2
fi

# ── Accessors and writers for this provider ──────────────────────────────────
# Discovered per provider rather than listed: helpers that forward to an
# accessor, helpers that read a tfvars file themselves, and functions that write
# one. Followed to a fixpoint, since a helper forwarding to a wrapper is itself
# a wrapper and one pass stops at the first hop. Not cosmetic: azure reads 21
# keys instead of 36 without _read_tfvar, and 36 instead of 51 without the four
# readers preflight.sh and quickstart.sh define outside _common.sh.
wrappers=""
readers=""
writers=""
users=""
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
          case " $ACCESSORS$wrappers$readers " in
            *" $name "*) ;;
            *) wrappers="$wrappers $name"; grew=1 ;;
          esac
          ;;
        reader)
          case " $ACCESSORS$wrappers$readers " in
            *" $name "*) ;;
            *) readers="$readers $name"; grew=1 ;;
          esac
          ;;
        writer)
          case " $writers " in *" $name "*) ;; *) writers="$writers $name" ;; esac
          ;;
        uses)
          case " $users " in *" $name "*) ;; *) users="$users $name" ;; esac
          ;;
      esac
    done <<EOF
$(_func_classes "$ACCESSORS$wrappers$readers" "$REPO_ROOT/$f")
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
all_accessors="$ACCESSORS$wrappers$readers"

# ── Check 5: the accessor registry is still complete ─────────────────────────
# The name rule, kept for what behavior cannot see: a helper named for tfvars
# that discovery did not classify and that reaches no accessor of its own. It
# either reads a tfvars file in a shape nothing here follows, or it is dead.
# Writers are exempt: check 2 already reads their heredocs.
# Scanned across every script, not just _common.sh: azure defines four readers
# in preflight.sh and quickstart.sh, gcp one in setup-env.sh.
unfollowed=""
for f in $scripts; do
  for fn in $(grep -oE '^[ ]*(function[ ]+)?[A-Za-z_][A-Za-z0-9_]*[ ]*\(\)' "$REPO_ROOT/$f" \
      | sed 's/[ ()]//g; s/^function//' | grep tfvar); do
    case " $all_accessors $users $writers " in *" $fn "*) continue ;; esac
    case " $unfollowed " in *" $fn "*) ;; *) unfollowed="$unfollowed $fn" ;; esac
  done
done
if [ -n "$unfollowed" ]; then
  echo "contracts: $arg defines$unfollowed, named for tfvars but neither followed as" >&2
  echo "an accessor nor calling one. Give it a shape this can follow, or add it to" >&2
  echo "ACCESSORS, or the keys read through it go unchecked. If it never touches a" >&2
  echo "tfvars file and only names one in a message, rename it." >&2
  exit 2
fi

echo "   accessors: $ACCESSORS${wrappers:+ (+ wrapper$wrappers)}${readers:+ (+ reader$readers)}"

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
        # The file argument decides which root the key belongs to. A bare
        # *.tfvars name, or a path built from the script's own location as aws
        # preflight.sh builds the argument it hands _tfvars_get, resolves
        # against INFRA_DIR -- the same root as variables.tf. A path naming
        # another module does not.
        if [ "$kind" = file ]; then
          case "$b" in
            ""|*modules/*)
              echo "contracts: $f:$lineno reads $a from \"$b\", which is not under" >&2
              echo "$arg/infra, so its root module is unknown." >&2
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
# The demotion above is by bare name, so a root variable sharing a name with a
# block field -- aws has name, default, min_size, max_size -- is demoted too and
# can never be reported. Print the set so a masked name is at least visible.
[ -n "${NESTED# }" ] && echo "   block fields, so noted rather than reported when read:${NESTED% }"

# ── Check 2: keys written into a tfvars file ─────────────────────────────────
write_keys=""
for f in $scripts; do
  hd=$(_tfvars_heredocs "$REPO_ROOT/$f") || {
    echo "contracts: $f: heredoc scan failed, see above" >&2; exit 2; }
  # The trailing COUNT record says how many tfvars heredocs were opened, which
  # COUNT tells "this file writes none" apart from "the extraction broke". Both
  # produce an empty key set, and one is a clean bill of health for content
  # nothing looked at.
  opened=$(printf '%s\n' "$hd" | awk -F"$TAB" '$1 == "COUNT" { print $2 }')
  hd=$(printf '%s\n' "$hd" | grep -v "^COUNT$TAB")
  # A tfvars heredoc whose body is one "$content" expansion legitimately yields
  # no keys (test-permutations.sh _write_override); one full of key = value
  # lines that yields none means the extractor stopped matching.
  hd_assigns=$(printf '%s\n' "$hd" \
    | grep -cE "^[0-9]+${TAB}[ ${TAB}]*[A-Za-z_][A-Za-z0-9_-]*[ ${TAB}]*=[^=]" | tr -d ' ')
  hd_keys=""
  if [ -n "$hd" ]; then
    # Piped separately from the sort below: a pipeline reports only its last
    # command status, which would swallow the unbalanced-braces exit.
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
# all. This is #140 -- setup-env.sh exporting three secrets the GCP root did not
# declare -- run automatically.
#
# Comments are stripped first. Most of these names are not exported directly:
# they are arguments to _sm_secret and _ssm_secret, so the scan cannot narrow to
# `export TF_VAR_x=` without dropping ten of aws's sixteen. What it can do is
# skip a commented-out line, which otherwise reports a variable deleted along
# with its export.
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
# enable_${addon} over three add-ons, and all six names are declared today, but
# nothing here proves that. A field inside a block value is real and readable
# but is not a root variable. Passing over either silently is the same
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
