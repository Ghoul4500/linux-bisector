#!/usr/bin/env bash
# lore-pr.sh — turn a lore.kernel.org patch series into a pull request
# against one of the OGC kernel repos.
#
#   ./lore-pr.sh https://lore.kernel.org/platform-driver-x86/20260817....@example.com/
#
# No flag  -> OpenGamingCollective/linux      (base auto-detected: features/*)
# -u       -> OpenGamingCollective/linux-unstable (base: master)
#
# Everything below the CONFIG block is generic; retarget it by editing the
# tables or by exporting the matching LORE_PR_* variable.
set -euo pipefail

basedir=$(cd "$(dirname "$0")" && pwd)

# ----------------------------------------------------------------- config --
: "${LORE_PR_REPO:=$basedir/linux}"          # local kernel clone (for objects)
: "${LORE_PR_TARGET:=ogc}"                   # default target key
: "${LORE_PR_BRANCH_PREFIX:=lore/}"          # branch namespace
: "${LORE_PR_WORKTREE:=$basedir/.lore-pr-wt}"
: "${LORE_PR_FORK_SUFFIX:=-ogc}"             # name for a same-network fork we create

# target key -> "github repo|git remote|default base|PR title prefix"
target_row() {
	case "$1" in
	ogc)      echo "OpenGamingCollective/linux|ogc|@auto|[FROM-ML] " ;;
	unstable) echo "OpenGamingCollective/linux-unstable|unstable|master|" ;;
	*)        return 1 ;;
	esac
}

# Touched paths -> OGC feature branch. First match wins, so order matters.
guess_feature_branch() {
	local p=$1
	case "$p" in
	*drivers/platform/x86/asus-*|*drivers/hid/hid-asus*) echo features/asus ;;
	*drivers/hid/usbhid/*|*drivers/hid/hid-core.c*)      echo features/usb-hid ;;
	*drivers/hid/hid-ayaneo*|*ayn-ec*|*drivers/platform/x86/ayn*) echo features/ayaneo ;;
	*drivers/hid/hid-msi*|*msi-claw*)                    echo features/msi-claw ;;
	*oxpec*|*drivers/hid/hid-oxp*|*onexplayer*)          echo features/onexplayer ;;
	*drivers/platform/x86/lenovo*|*ideapad*|*think*)     echo features/lenovo ;;
	*drivers/platform/x86/steamdeck*|*hid-steam*)        echo features/steamdeck ;;
	*leds-valve*|*steammachine*)                         echo features/steammachine ;;
	*drivers/iio/imu/bmi270*)                            echo features/bmi270 ;;
	*drivers/mmc/*)                                      echo features/mmc-fixes ;;
	*dmem*)                                              echo features/dmem-cgroups ;;
	*drm/amd/display*|*amdgpu*vrr*|*freesync*)           echo features/vrr ;;
	*kernel/sched/*)                                     echo features/scheduler ;;
	*drivers/gpu/drm/panel*)                             echo features/panels ;;
	*vram*overcommit*|*ttm*)                             echo features/vram-overcommit ;;
	*) echo features/fixes ;;
	esac
}

# ------------------------------------------------------------------ usage --
usage() {
	cat >&2 <<EOF
usage: $(basename "$0") [options] <lore-url-or-message-id>

  -u, --unstable         target linux-unstable instead of linux
  -T, --to KEY           target key explicitly (ogc|unstable)
  -b, --base BRANCH      PR base branch (default: master, or auto for ogc)
  -B, --branch NAME      branch name to create (default: derived from subject)
  -o, --origin           push to your own fork instead of the org repo
  -v, --version N        pick series revision vN
  -P, --pick RANGE       cherry-pick a subset, e.g. 1-2,4
  -p, --prefix STR       PR title prefix (default per target)
      --no-prefix        no PR title prefix
  -n, --dry-run          apply patches, show the plan, push nothing
  -y, --yes              do not prompt before opening the PR
  -k, --keep             keep the worktree after finishing
  -h, --help             this message
EOF
	exit "${1:-2}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '\033[36m%s\033[0m %s\n' "$1" "${2-}"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

# Ask before anything that touches a remote. Never blocks when there is no tty.
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

# ------------------------------------------------------------------- args --
target=$LORE_PR_TARGET
base=""; branch=""; use_origin=0; wantver=""; pick=""
prefix=""; prefix_set=0; dry=0; assume_yes=0; keep=0; msgid=""

while [ $# -gt 0 ]; do
	case "$1" in
	-u|--unstable) target=unstable ;;
	-T|--to)       target=${2:?}; shift ;;
	-b|--base)     base=${2:?}; shift ;;
	-B|--branch)   branch=${2:?}; shift ;;
	-o|--origin)   use_origin=1 ;;
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
	command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed${
		}$([ "$tool" = b4 ] && echo ' (pacman -S b4, or uv tool install b4)')"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"
[ -d "$LORE_PR_REPO/.git" ] || die "not a git repo: $LORE_PR_REPO (set LORE_PR_REPO)"

row=$(target_row "$target") || die "unknown target '$target' (known: ogc, unstable)"
IFS='|' read -r base_repo remote default_base def_prefix <<<"$row"
[ "$prefix_set" = 1 ] || prefix=$def_prefix
[ -n "$base" ] || base=$default_base

# lore URL -> bare message-id
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

# ---------------------------------------------------------------- cleanup --
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

# ------------------------------------------------------- fetch the series --
note "series" "$msgid"
# -3 makes b4 materialise the patches' pre-image blobs in the repo, which is what
# lets `git am -3` resolve a series against a base that has since moved on.
b4_args=(am -o "$workdir" -n series -l -3 --no-partial-reroll)
[ -z "$wantver" ] || b4_args+=(-v "$wantver")
[ -z "$pick" ] || b4_args+=(-P "$pick")
(cd "$LORE_PR_REPO" && b4 "${b4_args[@]}" "$msgid") >"$workdir/b4.log" 2>&1 || {
	sed 's/^/  /' "$workdir/b4.log" >&2; die "b4 am failed"
}
sed 's/^/  /' "$workdir/b4.log" | grep -E 'Total patches|Cover:|✗|✓' || true

mbx=$(find "$workdir" -maxdepth 1 -name 'series*.mbx' | head -n1)
[ -n "$mbx" ] || { sed 's/^/  /' "$workdir/b4.log" >&2; die "b4 produced no patches"; }
cover=$(find "$workdir" -maxdepth 1 -name 'series*.cover' | head -n1)
n_patches=$(grep -c '^From ' "$mbx" || true)

# ----------------------------------------------------- title, body, paths --
# RFC822 headers may be folded across lines; rejoin them before reading Subject.
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

# A cover letter is an email: it ends with a diffstat, a base-commit line and a
# git signature. GitHub renders its own diffstat, the one-space indent mangles
# under markdown, and the "-- " right below base-commit is a setext underline
# that turns that line into a heading. Cut the lot, and promote the shortlog's
# indented subjects to a real markdown list.
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


if [ -n "$cover" ]; then
	subject=$(unfold_headers "$cover" | sed -n 's/^Subject: //p' | head -n1)
	body=$(sed '1,/^$/d' "$cover")
else
	subject=$(unfold_headers "$mbx" | sed -n 's/^Subject: //p' | head -n1)
	body=""
fi
# strip the [PATCH ...] tag that lore/b4 keeps on the subject line
title=$(printf '%s' "$subject" | strip_tag)
[ -n "$title" ] || die "could not determine a title for the series"

paths=$(grep -oE '^diff --git a/[^ ]+' "$mbx" | sed 's|^diff --git a/||' | sort -u)
[ -n "$paths" ] || die "series touches no files — refusing to open an empty PR"

if [ "$base" = "@auto" ]; then
	base=$(guess_feature_branch "$(printf '%s\n' "$paths" | tr '\n' ' ')")
	auto_note=" (auto)"
else
	auto_note=""
fi

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

# ------------------------------------------------------- resolve head repo --
network() { gh api "repos/$1" --jq '.source.full_name // .full_name' 2>/dev/null; }

base_net=$(network "$base_repo") || die "cannot read $base_repo via gh"
head_repo=$base_repo
push_url="git@github.com:${base_repo}.git"

if [ "$use_origin" = 1 ]; then
	gh_user=$(gh api user --jq .login)
	cand=$(git -C "$LORE_PR_REPO" remote get-url origin 2>/dev/null \
		| sed -E 's#^.*github\.com[:/]##; s#\.git$##') || cand=""
	head_repo=""
	if [ -n "$cand" ] && [ "$(network "$cand" || true)" = "$base_net" ]; then
		head_repo=$cand
	else
		[ -z "$cand" ] || warn "$cand is in the ${cand:+$(network "$cand" || echo unknown)} network, but $base_repo is in $base_net"
		alt="${gh_user}/$(basename "$base_repo")${LORE_PR_FORK_SUFFIX}"
		if [ "$(network "$alt" 2>/dev/null || true)" = "$base_net" ]; then
			head_repo=$alt
			note "fork" "reusing $alt"
		else
			printf 'No fork of %s exists under %s.\n' "$base_repo" "$gh_user" >&2
			if confirm "Create $alt now?"; then
				gh repo fork "$base_repo" --fork-name "$(basename "$alt")" --clone=false --remote=false \
					|| die "gh repo fork failed"
				head_repo=$alt
			else
				die "--origin into $base_repo needs a fork in the $base_net network; create one with:
       gh repo fork $base_repo --fork-name $(basename "$alt") --clone=false"
			fi
		fi
	fi
	push_url="git@github.com:${head_repo}.git"
fi

# ------------------------------------------------------------ apply series --
note "target" "$base_repo"
note "base  " "${base}${auto_note}"
note "head  " "${head_repo}:${branch}"
note "title " "${prefix}${title}"
note "patches" "$n_patches touching $(printf '%s\n' "$paths" | wc -l) file(s)"

git -C "$LORE_PR_REPO" fetch --quiet "$remote" "$base" \
	|| die "cannot fetch $base from remote '$remote' — is it configured in $LORE_PR_REPO?"
base_sha=$(git -C "$LORE_PR_REPO" rev-parse FETCH_HEAD)

# The OGC branches carry these patches under their original subject, so a series
# that has already landed is cheap to spot — and is the common case for a resend.
series_subjects=$(unfold_headers "$mbx" | sed -n 's/^Subject: //p' | strip_tag)
base_subjects=$(git -C "$LORE_PR_REPO" log -n 500 --format=%s "$base_sha" | strip_tag)
present=0; missing=0
while IFS= read -r subj; do
	[ -n "$subj" ] || continue
	if printf '%s\n' "$base_subjects" | grep -qxF "$subj"; then
		present=$((present + 1))
	else
		missing=$((missing + 1))
	fi
done <<<"$series_subjects"

if [ "$missing" = 0 ] && [ "$present" -gt 0 ]; then
	note "already" "all $present patch(es) are on ${base_repo}:${base} — nothing to do"
	exit 0
fi
[ "$present" = 0 ] || warn "$present of $((present + missing)) patch(es) already on $base — expect conflicts"

git -C "$LORE_PR_REPO" worktree remove --force "$LORE_PR_WORKTREE" 2>/dev/null || true
git -C "$LORE_PR_REPO" branch -D "$branch" 2>/dev/null || true
note "worktree" "checking out $base at ${base_sha:0:12} (this takes a moment)"
git -C "$LORE_PR_REPO" worktree add --quiet -b "$branch" "$LORE_PR_WORKTREE" "$base_sha"
wt_added=1

if ! git -C "$LORE_PR_WORKTREE" am --quiet -3 "$mbx" 2>"$workdir/am.log"; then
	sed 's/^/  /' "$workdir/am.log" >&2
	git -C "$LORE_PR_WORKTREE" am --show-current-patch=diff 2>/dev/null | head -20 >&2 || true
	git -C "$LORE_PR_WORKTREE" am --abort 2>/dev/null || true
	keep=1
	die "series does not apply cleanly onto ${base_repo}:${base}
       the worktree is left at $LORE_PR_WORKTREE to fix by hand
       or retry with a different base, e.g. --base master"
fi
# The OGC feature branches carry the marker on the commits themselves, not just
# on the PR title, so rewrite the subjects we just applied. Idempotent, and a
# no-op for targets with an empty prefix (linux-unstable).
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
pr_body=$(printf '%s\n\n---\n\nApplied with `b4` from the mailing list.\nLink: https://lore.kernel.org/all/%s/\n' \
	"$summary" "$msgid")

if [ "$dry" = 1 ]; then
	printf '\n\033[33mdry run\033[0m — nothing pushed. Worktree: %s\n' "$LORE_PR_WORKTREE"
	git -C "$LORE_PR_WORKTREE" log --oneline --reverse "${base_sha}..HEAD"
	keep=1
	exit 0
fi

# -------------------------------------------------------------- push + PR --
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
