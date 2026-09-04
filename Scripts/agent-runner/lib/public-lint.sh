#!/usr/bin/env bash
# public-lint: nothing private reaches the public repository.
#   public_lint_range <base> <head>   diffs + commit messages (never author headers) + binary blobs
#   public_lint_text  <file|->        a PR body, comment or issue body
# Generic patterns live here. Name/host patterns live ONLY in the untracked
# $AGENT_BASE/public-denylist (one extended regex per line, 0600) — never in this file.

_lint_patterns() {
  cat <<'PAT'
[a-z0-9-]+\.ts\.net
\b100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b
\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b
https?://(?!localhost|127\.0\.0\.1)[a-z0-9.-]+:8787
\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b
\b0000[0-9A-Fa-f]{4}-[0-9A-Fa-f]{16}\b
ghs_[A-Za-z0-9]{30,}
ghp_[A-Za-z0-9]{30,}
github_pat_[A-Za-z0-9_]{20,}
sk-ant-[A-Za-z0-9_-]{10,}
(^|[^/\w])/home/[a-z_][a-z0-9_-]*
(^|[^/\w])/Users/[A-Za-z_][A-Za-z0-9_-]*
[A-Za-z0-9._%+-]+@gmail\.com
PAT
  [ -r "$AGENT_BASE/public-denylist" ] && grep -v '^\s*$' "$AGENT_BASE/public-denylist"
}

_lint_stream() {  # stdin -> prints hits, returns 1 when any (perl: portable PCRE, GNU or BSD hosts)
  local hits
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
  { git diff "$base...$head"; git log --format=%B "$base..$head"; } | _lint_stream || rc=1
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
