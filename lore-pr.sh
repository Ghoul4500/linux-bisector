#!/usr/bin/env bash
# lore-pr.sh <lore-url-or-message-id>: open a PR from a lore series.
# Commits already in linux-next are cherry-picked (-sex), the rest b4 am'd.
# Repos come from lore-pr.conf (see lore-pr.conf.example).
set -euo pipefail

basedir=$(cd "$(dirname "$0")" && pwd)

# config
conf=${LORE_PR_CONF:-$basedir/lore-pr.conf}
if [ -f "$conf" ]; then
	. "$conf"
fi

: "${LORE_PR_REPO:=$basedir/linux}"
: "${LORE_PR_NEXT_REMOTE:=}"
: "${LORE_PR_NEXT_BRANCH:=master}"
: "${LORE_PR_NEXT_LOOKBACK:=1 year}"
: "${LORE_PR_FORKS:=}"
: "${LORE_PR_TARGET:=}"
: "${LORE_PR_TARGETS:=}"
: "${LORE_PR_BRANCH_PREFIX:=lore/}"
: "${LORE_PR_WORKTREE:=$basedir/.lore-pr-wt}"

table_row() {
	local key=$2 line k rest
	while IFS= read -r line; do
		line=${line#"${line%%[![:space:]]*}"}
		case "$line" in ''|'#'*) continue ;; esac
		k=${line%%|*}; rest=${line#*|}
		if [ "$k" = "$key" ]; then printf '%s\n' "$rest"; return 0; fi
	done <<<"$1"
	return 1
}
table_keys() {
	printf '%s\n' "$1" | sed -E '/^[[:space:]]*(#|$)/d; s/^[[:space:]]*//; s/\|.*//' \
		| paste -sd, - | sed 's/^$/none/'
}
target_row() { table_row "$LORE_PR_TARGETS" "$1"; }
target_keys() { table_keys "$LORE_PR_TARGETS"; }
fork_row() { table_row "$LORE_PR_FORKS" "$1"; }
fork_keys() { table_keys "$LORE_PR_FORKS"; }

# usage
usage() {
	cat >&2 <<EOF
usage: $(basename "$0") [options] <lore-url-or-message-id>

  -T, --to KEY           target from lore-pr.conf (known: $(target_keys))
  -b, --base BRANCH      PR base branch (default: from the target row)
  -H, --head FORK        push through this fork (name from lore-pr.conf, or
                         owner/repo; default: from the target row; "-" pushes
                         to the target repo itself). Known: $(fork_keys)
  -B, --branch NAME      branch name to create (default: derived from subject)
  -v, --version N        pick series revision vN
  -P, --pick RANGE       apply a subset of the series, e.g. 1-2,4
  -p, --prefix STR       PR/commit title prefix (default: from the target row)
      --no-prefix        no title prefix
  -n, --dry-run          apply, show the plan, push nothing
  -y, --yes              do not prompt before pushing / opening the PR
  -k, --keep             keep the worktree after finishing
  -h, --help             this message

config: $conf
EOF
	exit "${1:-2}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m%s\033[0m %s\n' "$1" "${2-}"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

confirm() {
	local reply
	[ "${assume_yes:-0}" != 1 ] || return 0
	printf '%s [y/N] ' "$1" >&2
	if ! { read -r reply </dev/tty; } 2>/dev/null; then
		printf '\n' >&2
		warn "no terminal available to confirm — assuming no"
		return 1
	fi
	case "$reply" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# args
target=$LORE_PR_TARGET
base=""; branch=""; wantver=""; pick=""; head_opt=""
prefix=""; prefix_set=0; dry=0; assume_yes=0; keep=0; msgid=""

while [ $# -gt 0 ]; do
	case "$1" in
	-T|--to)       target=${2:?}; shift ;;
	-b|--base)     base=${2:?}; shift ;;
	-H|--head)     head_opt=${2:?}; shift ;;
	-B|--branch)   branch=${2:?}; shift ;;
	-v|--version)  wantver=${2:?}; shift ;;
	-P|--pick)     pick=${2:?}; shift ;;
	-p|--prefix)   prefix=${2:?}; prefix_set=1; shift ;;
	--no-prefix)   prefix=""; prefix_set=1 ;;
	-n|--dry-run)  dry=1 ;;
	-y|--yes)      assume_yes=1 ;;
	-k|--keep)     keep=1 ;;
	-h|--help)     usage 0 ;;
	-*)            die "unknown option: $1 (try --help)" ;;
	*)             [ -z "$msgid" ] || die "only one message-id may be given"; msgid=$1 ;;
	esac
	shift
done

[ -n "$msgid" ] || usage

for tool in b4 gh git; do
	command -v "$tool" >/dev/null 2>&1 && continue
	[ "$tool" != b4 ] || die "b4 is not installed (pacman -S b4, or uv tool install b4)"
	die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
[ -d "$LORE_PR_REPO/.git" ] || die "not a git repo: $LORE_PR_REPO (set LORE_PR_REPO)"
[ -n "$LORE_PR_TARGETS" ] || die "no targets configured — copy lore-pr.conf.example to $conf"
[ -n "$target" ] || die "no target given — use --to KEY or set LORE_PR_TARGET (known: $(target_keys))"
[ -n "$LORE_PR_NEXT_REMOTE" ] || die "LORE_PR_NEXT_REMOTE is not set (the remote holding linux-next)"

row=$(target_row "$target") || die "unknown target '$target' (known: $(target_keys))"
IFS='|' read -r base_repo remote default_base def_prefix def_fork <<<"$row"
[ -n "$base_repo" ] && [ -n "$remote" ] && [ -n "$default_base" ] \
	|| die "malformed target row for '$target': need key|owner/repo|remote|base|prefix|fork"
[ "$prefix_set" = 1 ] || prefix=$def_prefix
[ -n "$base" ] || base=$default_base

fork=${head_opt:-$def_fork}
case "$fork" in
''|-)  head_repo=$base_repo ;;
*/*)   head_repo=$fork ;;
*)     head_repo=$(fork_row "$fork") \
         || die "unknown fork '$fork' (known: $(fork_keys)); add it to LORE_PR_FORKS in $conf" ;;
esac
[ -n "$head_repo" ] || die "fork '$fork' has an empty owner/repo in $conf"
push_url="git@github.com:${head_repo}.git"
git -C "$LORE_PR_REPO" remote get-url "$remote" >/dev/null 2>&1 \
	|| die "remote '$remote' for target '$target' does not exist in $LORE_PR_REPO"
git -C "$LORE_PR_REPO" remote get-url "$LORE_PR_NEXT_REMOTE" >/dev/null 2>&1 \
	|| die "LORE_PR_NEXT_REMOTE '$LORE_PR_NEXT_REMOTE' does not exist in $LORE_PR_REPO"

msgid=${msgid#<}; msgid=${msgid%>}
msgid=${msgid%%#*}
case "$msgid" in
https://*|http://*)
	msgid=${msgid#*://}                       # host/list/msgid/...
	msgid=${msgid#*/}; msgid=${msgid#*/}      # strip host and list
	msgid=${msgid%%/*}                        # strip /T/, /raw, trailing /
	;;
esac
[ -n "$msgid" ] || die "could not extract a message-id from the argument"

# cleanup
workdir=$(mktemp -d "${TMPDIR:-/tmp}/lore-pr.XXXXXX")
wt_added=0
cleanup() {
	local rc=$?
	[ "$keep" = 1 ] || rm -rf "$workdir"
	if [ "$wt_added" = 1 ] && [ "$keep" != 1 ]; then
		git -C "$LORE_PR_REPO" worktree remove --force "$LORE_PR_WORKTREE" 2>/dev/null || true
	fi
	[ "$rc" = 0 ] || printf '\033[31maborted.\033[0m\n' >&2
}
trap cleanup EXIT

# fetch the series
note "series" "$msgid"
# -3 fetches the pre-image blobs so git am -3 can resolve against a moved base
b4_args=(am -o "$workdir" -n series -c -l -3 --no-partial-reroll)
[ -z "$wantver" ] || b4_args+=(-v "$wantver")
[ -z "$pick" ] || b4_args+=(-P "$pick")
(cd "$LORE_PR_REPO" && b4 "${b4_args[@]}" "$msgid") >"$workdir/b4.log" 2>&1 || {
	sed 's/^/  /' "$workdir/b4.log" >&2; die "b4 am failed"
}
sed 's/^/  /' "$workdir/b4.log" | grep -iE 'Total patches|Cover:|newer|✗|✓' || true

mbx=$(find "$workdir" -maxdepth 1 -name 'series*.mbx' | head -n1)
[ -n "$mbx" ] || { sed 's/^/  /' "$workdir/b4.log" >&2; die "b4 produced no patches"; }
cover=$(find "$workdir" -maxdepth 1 -name 'series*.cover' | head -n1)

mkdir -p "$workdir/split"
git mailsplit -o"$workdir/split" "$mbx" >/dev/null
mapfile -t patch_files < <(find "$workdir/split" -maxdepth 1 -type f | sort)
[ "${#patch_files[@]}" -gt 0 ] || die "could not split the mbox"

# title, body, paths
# rejoin folded headers
unfold_headers() {
	awk '
	BEGIN { inh = 1; held = "" }
	/^From [^ ]+ / { if (held != "") { print held; held = "" } inh = 1; print; next }
	{
		if (!inh) { print; next }
		if ($0 ~ /^[ \t]/ && held != "") { l = $0; sub(/^[ \t]+/, " ", l); held = held l; next }
		if (held != "") { print held; held = "" }
		if ($0 == "") { inh = 0; print ""; next }
		held = $0
	}
	END { if (held != "") print held }
	' "$1"
}
strip_tag() { sed -E 's/^(\[[^]]*\][[:space:]]*)+//'; }

# drop diffstat/base-commit/signature ("-- " is a markdown underline) and
# turn the indented shortlog into a list
clean_cover() {
	awk '
	/^-- $/ { exit }
	/^base-commit:/ { exit }
	/^ +[^ ].*\| +([0-9]+|Bin)/ { exit }
	{
		if ($0 ~ /^  [^ ]/) {
			if (!bullet && last != "") print ""
			bullet = 1
			sub(/^  /, "- ")
		} else {
			bullet = 0
		}
		print
		last = $0
	}
	' | awk '{ buf[n++] = $0 }
	END { while (n > 0 && buf[n-1] ~ /^[[:space:]]*$/) n--
	      for (i = 0; i < n; i++) print buf[i] }'
}
header() { unfold_headers "$1" | sed -n "s/^$2: //p" | head -n1; }
patch_msgid() { header "$1" 'Message-I[dD]' | sed 's/^<//; s/>.*//'; }
patch_subject() { header "$1" Subject | strip_tag; }

if [ -n "$cover" ]; then
	title=$(header "$cover" Subject | strip_tag)
	body=$(sed '1,/^$/d' "$cover")
else
	title=$(patch_subject "${patch_files[0]}")
	body=""
fi
[ -n "$title" ] || die "could not determine a title for the series"

paths=$(grep -oE '^diff --git a/[^ ]+' "$mbx" | sed 's|^diff --git a/||' | sort -u)
[ -n "$paths" ] || die "series touches no files — refusing to open an empty PR"

if [ -z "$branch" ]; then
	slug=$(printf '%s' "$title" \
		| sed -E 's#^[a-zA-Z0-9_/]+: ##; s#^[a-zA-Z0-9_/-]+: ##' \
		| tr '[:upper:]' '[:lower:]' \
		| sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
		| awk '{ if (length($0) > 48) { s = substr($0, 1, 48); sub(/-[^-]*$/, "", s); print s } else print }' \
		| sed -E 's/-+$//')
	[ -n "$slug" ] || slug="lore-$(date +%Y%m%d%H%M)"
	branch="${LORE_PR_BRANCH_PREFIX}${slug}"
fi

# same network?
network() { gh api "repos/$1" --jq '.source.full_name // .full_name' 2>/dev/null; }
if [ "$head_repo" != "$base_repo" ]; then
	base_net=$(network "$base_repo") || die "cannot read $base_repo via gh"
	head_net=$(network "$head_repo") || die "cannot read $head_repo via gh"
	[ "$base_net" = "$head_net" ] \
		|| die "$head_repo is a fork of $head_net, but $base_repo is a fork of $base_net
       pick a fork in the right network with --head (known: $(fork_keys))"
fi

# fetch refs
note "target" "$base_repo"
note "base  " "$base"
note "head  " "${head_repo}:${branch}"
note "title " "${prefix}${title}"
note "patches" "${#patch_files[@]} touching $(printf '%s\n' "$paths" | wc -l) file(s)"

git -C "$LORE_PR_REPO" fetch --quiet "$remote" "$base" \
	|| die "cannot fetch $base from remote '$remote'"
base_sha=$(git -C "$LORE_PR_REPO" rev-parse FETCH_HEAD)

note "next  " "fetching ${LORE_PR_NEXT_REMOTE}/${LORE_PR_NEXT_BRANCH}"
git -C "$LORE_PR_REPO" fetch --quiet "$LORE_PR_NEXT_REMOTE" "$LORE_PR_NEXT_BRANCH" \
	|| die "cannot fetch $LORE_PR_NEXT_BRANCH from remote '$LORE_PR_NEXT_REMOTE'"
next_sha=$(git -C "$LORE_PR_REPO" rev-parse FETCH_HEAD)

# already on the base?
base_subjects=$(git -C "$LORE_PR_REPO" log -n 500 --format=%s "$base_sha" | strip_tag)
present=0; missing=0
for f in "${patch_files[@]}"; do
	subj=$(patch_subject "$f")
	[ -n "$subj" ] || continue
	if printf '%s\n' "$base_subjects" | grep -qxF "$subj"; then
		present=$((present + 1))
	else
		missing=$((missing + 1))
	fi
done
if [ "$missing" = 0 ] && [ "$present" -gt 0 ]; then
	note "already" "all $present patch(es) are on ${base_repo}:${base} — nothing to do"
	exit 0
fi
[ "$present" = 0 ] || warn "$present of $((present + missing)) patch(es) already on $base — expect conflicts"

# look up in linux-next
# by Link: message-id first, then exact subject
find_in_next() {
	local mid=$1 subj=$2 sha
	if [ -n "$mid" ]; then
		sha=$(git -C "$LORE_PR_REPO" log -n1 --format=%H -F --grep="$mid" \
			--since="$LORE_PR_NEXT_LOOKBACK" "${base_sha}..${next_sha}")
		[ -z "$sha" ] || { printf '%s\n' "$sha"; return 0; }
	fi
	if [ -n "$subj" ]; then
		sha=$(git -C "$LORE_PR_REPO" log --format='%H%x09%s' -F --grep="$subj" \
			--since="$LORE_PR_NEXT_LOOKBACK" "${base_sha}..${next_sha}" \
			| awk -F'\t' -v s="$subj" '$2 == s { print $1; exit }')
		[ -z "$sha" ] || { printf '%s\n' "$sha"; return 0; }
	fi
	return 1
}

picks=()      # shas found in linux-next, series order
ml_only=()    # split files that have to come from the list
for f in "${patch_files[@]}"; do
	mid=$(patch_msgid "$f"); subj=$(patch_subject "$f")
	if sha=$(find_in_next "$mid" "$subj"); then
		picks+=("$sha")
		note "next  " "${sha:0:12} $subj"
	else
		ml_only+=("$f")
		note "list  " "$subj"
	fi
done

case "${#picks[@]}/${#ml_only[@]}" in
*/0) source_note="cherry-picked from linux-next (${LORE_PR_NEXT_REMOTE}/${LORE_PR_NEXT_BRANCH})" ;;
0/*) source_note="applied with \`b4 am\` from the mailing list" ;;
*)   source_note="${#picks[@]} commit(s) cherry-picked from linux-next, ${#ml_only[@]} applied with \`b4 am\` from the mailing list"
     warn "series is only partially in linux-next — mixing cherry-pick and b4 am" ;;
esac

# worktree
git -C "$LORE_PR_REPO" worktree remove --force "$LORE_PR_WORKTREE" 2>/dev/null || true
git -C "$LORE_PR_REPO" branch -D "$branch" 2>/dev/null || true
note "worktree" "checking out $base at ${base_sha:0:12} (this takes a moment)"
git -C "$LORE_PR_REPO" worktree add --quiet -b "$branch" "$LORE_PR_WORKTREE" "$base_sha"
wt_added=1

leave_worktree() {
	keep=1
	die "$1
       the worktree is left at $LORE_PR_WORKTREE to fix by hand
       or retry with a different base, e.g. --base master"
}

if [ "${#picks[@]}" -gt 0 ]; then
	cp_flags=(-s -x); cp_in=/dev/null
	if [ -t 0 ] && [ -t 1 ]; then
		cp_flags+=(-e); cp_in=/dev/tty
	else
		warn "no terminal — cherry-picking without -e"
	fi
	if ! git -C "$LORE_PR_WORKTREE" cherry-pick "${cp_flags[@]}" "${picks[@]}" <"$cp_in" 2>"$workdir/cp.log"; then
		sed 's/^/  /' "$workdir/cp.log" >&2
		git -C "$LORE_PR_WORKTREE" status --short 2>/dev/null | head -20 >&2 || true
		git -C "$LORE_PR_WORKTREE" cherry-pick --abort 2>/dev/null || true
		leave_worktree "cherry-pick from linux-next does not apply cleanly onto ${base_repo}:${base}"
	fi
fi

if [ "${#ml_only[@]}" -gt 0 ]; then
	if ! git -C "$LORE_PR_WORKTREE" am --quiet -3 -s "${ml_only[@]}" 2>"$workdir/am.log"; then
		sed 's/^/  /' "$workdir/am.log" >&2
		git -C "$LORE_PR_WORKTREE" am --show-current-patch=diff 2>/dev/null | head -20 >&2 || true
		git -C "$LORE_PR_WORKTREE" am --abort 2>/dev/null || true
		leave_worktree "series does not apply cleanly onto ${base_repo}:${base}"
	fi
fi

if [ -n "$prefix" ]; then
	FILTER_BRANCH_SQUELCH_WARNING=1 LORE_PR_MSG_PREFIX="$prefix" \
	git -C "$LORE_PR_WORKTREE" filter-branch -f --msg-filter '
		IFS= read -r subject
		case "$subject" in
		"$LORE_PR_MSG_PREFIX"*) printf "%s\n" "$subject" ;;
		*) printf "%s%s\n" "$LORE_PR_MSG_PREFIX" "$subject" ;;
		esac
		cat
	' "${base_sha}..HEAD" >/dev/null 2>&1 \
		|| die "could not prefix commit subjects with '$prefix'"
	note "prefix" "tagged $(git -C "$LORE_PR_WORKTREE" rev-list --count "${base_sha}..HEAD") commit subject(s) with '$prefix'"
fi

applied=$(git -C "$LORE_PR_WORKTREE" rev-list --count "${base_sha}..HEAD")
note "applied" "$applied commit(s) cleanly onto $base"

summary=""
[ -z "$body" ] || summary=$(printf '%s\n' "$body" | clean_cover)
[ -n "$summary" ] || summary=$(git -C "$LORE_PR_WORKTREE" log --reverse --format='- %s' "${base_sha}..HEAD")
pr_body=$(printf '%s\n\n---\n\nSource: %s.\nLink: https://lore.kernel.org/all/%s/\n' \
	"$summary" "$source_note" "$msgid")

if [ "$dry" = 1 ]; then
	printf '\n\033[33mdry run\033[0m — nothing pushed. Worktree: %s\n' "$LORE_PR_WORKTREE"
	git -C "$LORE_PR_WORKTREE" log --oneline --reverse "${base_sha}..HEAD"
	keep=1
	exit 0
fi

# push + PR
push_flags=()
if git ls-remote --exit-code --heads "$push_url" "$branch" >/dev/null 2>&1; then
	warn "$head_repo already has branch $branch"
	confirm "Force-update it?" || die "not pushing; pick another name with --branch"
	push_flags=(--force)
fi
note "push  " "$head_repo -> $branch"
git -C "$LORE_PR_WORKTREE" push "${push_flags[@]+"${push_flags[@]}"}" "$push_url" "HEAD:refs/heads/$branch"

head_ref=$branch
[ "$head_repo" = "$base_repo" ] || head_ref="${head_repo%%/*}:$branch"

printf '\nOpen PR \033[1m%s\033[0m\n  %s  <-  %s\n' \
	"${prefix}${title}" "${base_repo}:${base}" "${head_repo}:${branch}"
if ! confirm "Proceed?"; then
	printf 'Branch is pushed; no PR opened. To open it later:\n  gh pr create -R %s -B %s -H %s -t %s\n' \
		"$base_repo" "$base" "$head_ref" "$(printf '%q' "${prefix}${title}")"
	exit 0
fi

printf '%s' "$pr_body" | gh pr create \
	-R "$base_repo" -B "$base" -H "$head_ref" \
	-t "${prefix}${title}" -F -
