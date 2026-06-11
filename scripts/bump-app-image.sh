#!/usr/bin/env bash
#
# Bump a pinned image/chart version. Handles the three layouts in this repo:
#
#   * Kustomize apps (apps/<app>/deployment.yaml) — rewrites the `image:` tag.
#   * multica (Helm, OCI)                         — rewrites BOTH image tags in
#     apps/multica/values.yaml AND MULTICA_CHART_VERSION in the Makefile, in
#     lockstep (one release == one number; images are vX.Y.Z, the chart is X.Y.Z).
#   * Classic-helm-repo charts (supabase, cert-manager, headlamp) — rewrites the
#     chart-version variable in the Makefile; the chart pins its own images.
#
# Tag discovery + existence checks are registry-aware: Docker Hub (e.g.
# bellamy/wallos) and GitHub Container Registry / ghcr.io OCI (multica's images
# and chart) are both supported. NOTHING is applied to the cluster — every bump
# lands as a reviewable git diff; you then run `make app APP=<app>` (kustomize)
# or the matching helm target (`make multica` / `make supabase` / ...).
#
# Usage:
#   ./scripts/bump-app-image.sh <app>            # show current + newest available versions
#   ./scripts/bump-app-image.sh <app> <version>  # pin <app> to <version>
#
# Requires: curl, python3 (both already used elsewhere in this repo).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

app="${1:-}"
version="${2:-}"
[[ -n "$app" ]] || { echo "usage: $0 <app> [version]" >&2; exit 1; }

CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-10}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"
CURL_RETRIES="${CURL_RETRIES:-2}"

_curl() {
  curl -fsSL \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    --retry "$CURL_RETRIES" \
    --retry-delay 1 \
    --retry-connrefused \
    "$@"
}

_fetch_json() {
  local label="$1" json
  shift
  if ! json="$(_curl "$@")"; then
    echo "ERROR: failed to fetch $label" >&2
    return 1
  fi
  printf '%s\n' "$json"
}

# --- registry-aware tag helpers ---------------------------------------------
# Resolve a docker-style ref (host optional) into REG (ghcr|hub) + REPO, so the
# rest of the script can list/verify tags without caring where the image lives.
REG=""; REPO=""
_resolve_ref() {
  local ref="$1" first
  first="${ref%%/*}"
  if [[ "$first" == "$ref" ]]; then                       # no slash -> Docker Hub
    REG=hub; REPO="$ref"
  elif [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
    case "$first" in                                       # first segment is a host
      ghcr.io) REG=ghcr; REPO="${ref#*/}" ;;
      docker.io|registry-1.docker.io|index.docker.io) REG=hub; REPO="${ref#*/}" ;;
      *) echo "ERROR: unsupported registry '$first' (only Docker Hub + ghcr.io)" >&2; exit 1 ;;
    esac
  else                                                     # owner/name -> Docker Hub
    REG=hub; REPO="$ref"
  fi
  if [[ "$REG" == hub && "$REPO" != */* ]]; then REPO="library/$REPO"; fi  # official image
}

# Emit every tag for the resolved repo, one per line (order not guaranteed).
_raw_tags() {
  if [[ "$REG" == ghcr ]]; then
    local tok_json tok tags_json
    tok_json="$(_fetch_json "GHCR auth token for $REPO" \
      "https://ghcr.io/token?scope=repository:${REPO}:pull")" || return 1
    tok="$(python3 -c 'import json, sys
label = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: invalid JSON from {label}: {e}", file=sys.stderr)
    sys.exit(1)
token = data.get("token")
if not token:
    print(f"ERROR: missing token in {label} response", file=sys.stderr)
    sys.exit(1)
print(token)' "GHCR auth token for $REPO" <<<"$tok_json")" || return 1
    tags_json="$(_fetch_json "GHCR tags for $REPO" \
      -H "Authorization: Bearer $tok" "https://ghcr.io/v2/${REPO}/tags/list")" || return 1
    python3 -c 'import json, sys
label = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: invalid JSON from {label}: {e}", file=sys.stderr)
    sys.exit(1)
tags = data.get("tags") or []
if not isinstance(tags, list):
    print(f"ERROR: invalid tags list in {label} response", file=sys.stderr)
    sys.exit(1)
print("\n".join(str(t) for t in tags))' "GHCR tags for $REPO" <<<"$tags_json"
  else
    local tags_json
    tags_json="$(_fetch_json "Docker Hub tags for $REPO" \
      "https://hub.docker.com/v2/repositories/${REPO}/tags?page_size=100&ordering=last_updated")" || return 1
    python3 -c 'import json, sys
label = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception as e:
    print(f"ERROR: invalid JSON from {label}: {e}", file=sys.stderr)
    sys.exit(1)
results = data.get("results") or []
if not isinstance(results, list):
    print(f"ERROR: invalid results list in {label} response", file=sys.stderr)
    sys.exit(1)
print("\n".join(str(t["name"]) for t in results if isinstance(t, dict) and "name" in t))' \
      "Docker Hub tags for $REPO" <<<"$tags_json"
  fi
}

# Print the newest <=10 plain semver (X.Y.Z, optional leading v) tags, indented.
_show_versions() {
  local tags
  tags="$(_raw_tags)" || return 1
  python3 -c 'import sys, re
tags = [l.strip() for l in sys.stdin if l.strip()]
sv = sorted({t for t in tags if re.fullmatch(r"v?\d+\.\d+\.\d+", t)},
            key=lambda s: list(map(int, s.lstrip("v").split("."))), reverse=True)
print("\n".join("  " + t for t in sv[:10]) or "  (no plain X.Y.Z tags found)")' <<<"$tags"
}

# Exit 0 if tag ($1) exists for the resolved repo, else non-zero.
_tag_exists() {
  if [[ "$REG" == hub ]]; then
    _curl -o /dev/null "https://hub.docker.com/v2/repositories/${REPO}/tags/$1"
  else
    local tags
    tags="$(_raw_tags)" || return 1
    grep -qxF "$1" <<<"$tags"
  fi
}

# --- mode: Kustomize app (apps/<app>/deployment.yaml) ------------------------
manifest="apps/$app/deployment.yaml"
if [[ -f "$manifest" ]]; then
  image_ref="$(grep -E '^[[:space:]]*image:' "$manifest" | head -1 \
    | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*#.*//')"
  repo="${image_ref%:*}"
  current="${image_ref##*:}"
  _resolve_ref "$repo"

  echo "App:     $app  (kustomize)"
  echo "Image:   $repo"
  echo "Current: $current"

  if [[ -z "$version" ]]; then
    echo
    echo "Newest published versions:"
    _show_versions
    echo
    echo "To pin:  $0 $app <version>"
    exit 0
  fi

  if ! _tag_exists "$version"; then
    echo "ERROR: tag '$version' not found for $repo" >&2
    exit 1
  fi
  if [[ "$version" == "$current" ]]; then
    echo "Already pinned to $version — nothing to do."
    exit 0
  fi

  # Replace only the tag on the image: line; keep any trailing comment intact.
  # -i.bak keeps this portable across BSD (macOS) and GNU sed.
  sed -i.bak -E "s|(image:[[:space:]]*${repo}:)[^[:space:]]+|\1${version}|" "$manifest"
  rm -f "${manifest}.bak"

  echo
  echo "Bumped $repo:  $current -> $version"
  echo "Review:  git diff $manifest"
  echo "Apply:   make app APP=$app"
  exit 0
fi

# --- mode: multica (Helm: image tags in values.yaml + chart version in Makefile) ---
if [[ "$app" == "multica" ]]; then
  values="apps/multica/values.yaml"
  chart_repo="ghcr.io/multica-ai/charts/multica"     # chart tags: X.Y.Z
  backend_repo="ghcr.io/multica-ai/multica-backend"  # image tags: vX.Y.Z
  frontend_repo="ghcr.io/multica-ai/multica-web"     # image tags: vX.Y.Z

  cur_chart="$(grep -E '^MULTICA_CHART_VERSION' Makefile | sed -E 's/.*[?]=[[:space:]]*//; s/[[:space:]]*#.*//')"
  cur_img="$(grep -E '^[[:space:]]+tag:' "$values" | head -1 | sed -E 's/.*tag:[[:space:]]*//')"

  echo "App:     multica  (helm)"
  echo "Chart:   $chart_repo   current: $cur_chart"
  echo "Images:  backend + frontend           current: $cur_img"

  if [[ -z "$version" ]]; then
    echo
    echo "Newest published chart versions:"
    _resolve_ref "$chart_repo"
    _show_versions
    echo
    echo "To pin (chart + both image tags, in lockstep):  $0 multica <version>"
    exit 0
  fi

  norm="${version#v}"        # accept 0.3.18 or v0.3.18
  chart_ver="$norm"          # chart is X.Y.Z
  img_tag="v$norm"           # images are vX.Y.Z

  _resolve_ref "$chart_repo"
  if ! _tag_exists "$chart_ver"; then
    echo "ERROR: chart version '$chart_ver' not found at $chart_repo" >&2
    exit 1
  fi
  for image_repo in "$backend_repo" "$frontend_repo"; do
    _resolve_ref "$image_repo"
    if ! _tag_exists "$img_tag"; then
      echo "ERROR: image tag '$img_tag' not found at $image_repo" >&2
      exit 1
    fi
  done

  if [[ "$chart_ver" == "$cur_chart" && "$img_tag" == "$cur_img" ]]; then
    echo "Already pinned to $version — nothing to do."
    exit 0
  fi

  # Makefile: MULTICA_CHART_VERSION ?= X.Y.Z   (no leading v)
  sed -i.bak -E "s|^(MULTICA_CHART_VERSION[[:space:]]*[?]=[[:space:]]*).*|\1${chart_ver}|" Makefile
  rm -f Makefile.bak
  # values.yaml: rewrite every semver-valued `tag:` line (the two image tags) to vX.Y.Z.
  # Non-semver tags (e.g. a pinned pg17) don't match, so they're left untouched.
  sed -i.bak -E "s|^([[:space:]]+tag:[[:space:]]*)v?[0-9]+\.[0-9]+\.[0-9]+|\1${img_tag}|" "$values"
  rm -f "${values}.bak"

  echo
  echo "Bumped multica:  chart $cur_chart -> $chart_ver,  images $cur_img -> $img_tag"
  echo "Review:  git diff Makefile $values"
  echo "Apply:   make multica"
  exit 0
fi

# --- mode: classic-helm-repo charts (chart version pinned as a Makefile variable) ---
# These charts pin their own image tags (or our values.yaml overrides none), so a
# "bump" is purely the chart-version number in the Makefile. Versions come from
# `helm search repo` (needs `make repos` to have added the repos).
helm_repo_spec() {  # echoes "<repo/chart> <Makefile variable>"
  case "$1" in
    supabase)     echo "supabase/supabase SUPABASE_CHART_VERSION" ;;
    cert-manager) echo "jetstack/cert-manager CERT_MANAGER_CHART_VERSION" ;;
    headlamp)     echo "headlamp/headlamp HEADLAMP_CHART_VERSION" ;;
    *) return 1 ;;
  esac
}

if spec="$(helm_repo_spec "$app")"; then
  chart="${spec%% *}"
  var="${spec##* }"
  cur_chart="$(grep -E "^${var}" Makefile | sed -E 's/.*[?]=[[:space:]]*//; s/[[:space:]]*#.*//')"
  echo "App:     $app  (helm)"
  echo "Chart:   $chart   current: $cur_chart"

  if [[ -z "$version" ]]; then
    echo
    echo "Newest published chart versions:"
    helm search repo "$chart" --versions 2>/dev/null | awk 'NR>1{print "  "$2}' | head -10 \
      || echo "  (run 'make repos' first to add the helm repos)"
    echo
    echo "To pin:  $0 $app <version>"
    exit 0
  fi

  # Accept the version with or without a leading v, then pin whichever form the
  # repo actually publishes (cert-manager tags vX.Y.Z; supabase/headlamp X.Y.Z).
  norm="${version#v}"
  avail="$(helm search repo "$chart" --versions 2>/dev/null | awk 'NR>1{print $2}')"
  if grep -qxF "$norm" <<<"$avail"; then
    pick="$norm"
  elif grep -qxF "v$norm" <<<"$avail"; then
    pick="v$norm"
  else
    echo "ERROR: chart version '$version' not found in $chart (run 'make repos' to refresh)" >&2
    exit 1
  fi
  if [[ "$pick" == "$cur_chart" ]]; then
    echo "Already pinned to $pick — nothing to do."
    exit 0
  fi

  sed -i.bak -E "s|^(${var}[[:space:]]*[?]=[[:space:]]*).*|\1${pick}|" Makefile
  rm -f Makefile.bak

  echo
  echo "Bumped $app chart:  $cur_chart -> $pick"
  echo "Review:  git diff Makefile"
  echo "Apply:   make $app"
  exit 0
fi

echo "ERROR: apps/$app/deployment.yaml not found, and '$app' is not a known Helm app." >&2
echo "       Kustomize apps need a deployment.yaml; multica, supabase, cert-manager and" >&2
echo "       headlamp are special-cased (Helm)." >&2
exit 1
