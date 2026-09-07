#!/usr/bin/env bash
# public-lint: nothing private reaches the public repository.
#   public_lint_range <base> <head>   added diff lines, commit messages AND author/committer
#                                     headers, plus binary blobs; cwd = the worktree
#   public_lint_text  <file|->        a PR body, comment, issue body — every model-authored text
#                                     is passed through here by tick.sh before it is posted
# Generic patterns live here. Name/host patterns live ONLY in the untracked
# $AGENT_BASE/public-denylist (one Perl regex per line, `#` comments allowed, 0600) — never in
# this file. FAIL-CLOSED: a missing or empty denylist refuses every lint (and therefore every
# push and every post) instead of silently proceeding without the owner's name and device names.
# The self-test in Scripts/agent-runner/tests/public-lint-test.sh pins every pattern below.

_lint_patterns() {
  cat <<'PAT'
(?i)[a-z0-9-]+\.ts\.net
\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b
\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b
\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b
\bfd7a:115c:a1e0:[0-9a-f:]+
\b[A-Za-z0-9-]+\.local(?![.\w-])(:[0-9]{2,5})?
https?://(?!localhost|127\.0\.0\.1)[a-z0-9.-]+:8787
\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b
\b0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}\b
gh[opsur]_[A-Za-z0-9]{30,}
github_pat_[A-Za-z0-9_]{20,}
sk-ant-[A-Za-z0-9_-]{10,}
\bpk_[0-9]+_[A-Za-z0-9]{32}\b
\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
(^|[^/\w])/home/[a-z_][a-z0-9_-]*
(^|[^/\w])/Users/[A-Za-z_][A-Za-z0-9_-]*
(^|[^/\w])/private/tmp/claude-[0-9]+/
\bclaude-[0-9]+/-(Users|home)-[A-Za-z]
\b(?![\w.%+-]+@(?:anthropic\.com|users\.noreply\.github\.com|github\.com|example\.(?:com|org|net))\b)[\w.%+-]+@[\w-]+(\.[\w-]+)*\.[A-Za-z]{2,}\b
(?<![\w'"/.-])(I|I'm|I've|I'd|I'll|my|myself)(?![\w'/.-])
PAT
  grep -v -E '^\s*(#|$)' "$AGENT_BASE/public-denylist"
}

# The host denylist must exist and carry at least one real pattern (the owner's name at minimum).
_lint_denylist_ok() {
  [ -r "${AGENT_BASE:-/nonexistent}/public-denylist" ] || return 1
  grep -q -v -E '^\s*(#|$)' "$AGENT_BASE/public-denylist"
}

_lint_stream() {  # stdin -> prints hits, returns 1 when any (perl: portable PCRE, GNU or BSD hosts)
  local hits
  if ! _lint_denylist_ok; then
    echo "  LINT: $AGENT_BASE/public-denylist is missing or has no patterns — refusing (fail closed)."
    return 1
  fi
  hits="$(perl -e '
      open(my $pf, "<", $ARGV[0]) or exit 0; my @p = map { chomp; qr/$_/ } grep { /\S/ } <$pf>; close $pf;
      my $n = 0; my @h;
      while (my $l = <STDIN>) { $n++; for my $r (@p) { if ($l =~ $r) { push @h, "$n:$l"; last } } last if @h >= 20 }
      print @h;' <(_lint_patterns))"
  [ -z "$hits" ] && return 0
  printf '%s' "$hits" | sed 's/^/  LINT: /'
  return 1
}

public_lint_text() {
  if [ "${1:--}" = "-" ]; then _lint_stream; else _lint_stream < "$1"; fi
}

public_lint_range() {  # <base> <head> ; cwd = the worktree
  local base="$1" head="$2" rc=0 blob
  {
    # Added lines only (-U0; drop "-" lines and "@@" hunk headers, whose function context is
    # already-public text): what is REMOVED from the public tree is not a leak. --text so
    # binary-looking content is scanned instead of skipped, and grep -a so a NUL byte does not
    # collapse the stream into "Binary file matches".
    git diff --text -U0 "$base...$head" | grep -a -v -E '^(-|@@)'
    git log --format=%B "$base..$head"
    git log --format='%an <%ae>%n%cn <%ce>' "$base..$head"
  } | _lint_stream || rc=1
  # Binary blobs: images larger than the table crop are refused by size class; every new image
  # needs an approval entry unless it is tiny.
  while IFS= read -r blob; do
    [ -n "$blob" ] || continue
    case "$blob" in
      *.jpg|*.jpeg|*.png|*.heic)
        if ! _approved_file "$blob" 2>/dev/null; then echo "  LINT: unapproved image $blob"; rc=1; fi ;;
    esac
  done < <(git diff --name-only --diff-filter=A "$base...$head")
  return $rc
}
