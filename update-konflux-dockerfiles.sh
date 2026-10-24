#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -b BRANCH

Update GO_BUILDER and RUNTIME SHAs in .konflux/dockerfiles/ across all downstream repos and create PRs.

Required:
  -b BRANCH        Release branch (e.g. release-v1.24.x)

Optional:
  -g GO_BUILDER    New GO_BUILDER image ref (full image@sha256:... or just the sha256 hex)
  -r RUNTIME       New RUNTIME image ref (full image@sha256:... or just the sha256 hex)
  -d REPOS_DIR     Path to config/downstream/repos (default: config/downstream/repos)
  -o ORG           GitHub org (default: openshift-pipelines)
  -c REPOS         Comma-separated list of repos to process (default: all)
  -i               Interactive mode — prompt for each repo (y/n/q)
  -n               Dry run — show what would be done without making changes
  -h               Show this help

Example:
  $(basename "$0") -b release-v1.24.x \\
    -g registry.access.redhat.com/ubi9/go-toolset:latest@sha256:abc123... \\
    -r registry.redhat.io/ubi9/ubi-minimal:latest@sha256:def456...
EOF
  exit 1
}

BRANCH=""
GO_SHA=""
RUNTIME_SHA=""
REPOS_DIR="config/downstream/repos"
ORG="openshift-pipelines"
DRY_RUN=false
INTERACTIVE=false
ONLY_REPOS=""

while getopts "b:g:r:d:o:c:inh" opt; do
  case $opt in
    b) BRANCH="$OPTARG" ;;
    g) GO_SHA="$OPTARG" ;;
    r) RUNTIME_SHA="$OPTARG" ;;
    d) REPOS_DIR="$OPTARG" ;;
    o) ORG="$OPTARG" ;;
    c) ONLY_REPOS="$OPTARG" ;;
    i) INTERACTIVE=true ;;
    n) DRY_RUN=true ;;
    h) usage ;;
    *) usage ;;
  esac
done

declare -A SELECTED_REPOS
if [[ -n "$ONLY_REPOS" ]]; then
  IFS=',' read -ra _repos <<< "$ONLY_REPOS"
  for r in "${_repos[@]}"; do
    SELECTED_REPOS["$r"]=1
  done
fi

[[ -z "$BRANCH" ]] && { echo "ERROR: -b BRANCH is required"; usage; }
[[ -z "$GO_SHA" && -z "$RUNTIME_SHA" ]] && { echo "ERROR: at least one of -g or -r must be provided"; usage; }

# Detect whether input is a full image ref or just a sha hex
GO_FULL_REF=""
if [[ -n "$GO_SHA" && "$GO_SHA" == *"@sha256:"* ]]; then
  GO_FULL_REF="$GO_SHA"
  GO_SHA=""
elif [[ -n "$GO_SHA" && "$GO_SHA" == *"/"* ]]; then
  echo "ERROR: -g looks like an image ref but missing @sha256: digest"; exit 1
fi

RUNTIME_FULL_REF=""
if [[ -n "$RUNTIME_SHA" && "$RUNTIME_SHA" == *"@sha256:"* ]]; then
  RUNTIME_FULL_REF="$RUNTIME_SHA"
  RUNTIME_SHA=""
elif [[ -n "$RUNTIME_SHA" && "$RUNTIME_SHA" == *"/"* ]]; then
  echo "ERROR: -r looks like an image ref but missing @sha256: digest"; exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
echo "Working directory: $WORKDIR"

PR_BRANCH="update-base-images-${BRANCH}"

get_repo_name() {
  local file="$1"
  local repo
  repo=$(grep -m1 '^repo:' "$file" 2>/dev/null | awk '{print $2}' || true)
  if [[ -z "$repo" ]]; then
    repo=$(grep -m1 '^name:' "$file" | awk '{print $2}')
  fi
  echo "$repo"
}

update_dockerfiles() {
  local repo_dir="$1"
  local dockerfile_dir="${repo_dir}/.konflux/dockerfiles"
  local changed=false

  if [[ ! -d "$dockerfile_dir" ]]; then
    echo "  No .konflux/dockerfiles/ directory, skipping"
    return 1
  fi

  for df in "$dockerfile_dir"/*.Dockerfile "$dockerfile_dir"/Dockerfile*; do
    [[ -f "$df" ]] || continue

    if [[ -n "$GO_FULL_REF" ]]; then
      if grep -q 'ARG GO_BUILDER=' "$df"; then
        sed -i.bak -E "s|ARG GO_BUILDER=.*|ARG GO_BUILDER=${GO_FULL_REF}|" "$df"
        rm -f "$df.bak"
        changed=true
      fi
    elif [[ -n "$GO_SHA" ]]; then
      if grep -q 'ARG GO_BUILDER=.*@sha256:' "$df"; then
        sed -i.bak -E "s|(ARG GO_BUILDER=.*@sha256:)[a-f0-9]+|\1${GO_SHA}|" "$df"
        rm -f "$df.bak"
        changed=true
      fi
    fi

    if [[ -n "$RUNTIME_FULL_REF" ]]; then
      if grep -q 'ARG RUNTIME=' "$df"; then
        sed -i.bak -E "s|ARG RUNTIME=.*|ARG RUNTIME=${RUNTIME_FULL_REF}|" "$df"
        rm -f "$df.bak"
        changed=true
      fi
    elif [[ -n "$RUNTIME_SHA" ]]; then
      if grep -q 'ARG RUNTIME=.*@sha256:' "$df"; then
        sed -i.bak -E "s|(ARG RUNTIME=.*@sha256:)[a-f0-9]+|\1${RUNTIME_SHA}|" "$df"
        rm -f "$df.bak"
        changed=true
      fi
    fi
  done

  $changed && return 0 || return 1
}

declare -A SEEN_REPOS
for yaml_file in "$REPOS_DIR"/*.yaml; do
  base=$(basename "$yaml_file" .yaml)
  [[ "$base" == operator-index* || "$base" == console-plugin* ]] && continue

  repo_name=$(get_repo_name "$yaml_file")
  [[ -z "$repo_name" ]] && { echo "WARN: no repo/name in $yaml_file, skipping"; continue; }
  [[ -n "${SEEN_REPOS[$repo_name]:-}" ]] && { echo "==> Skipping duplicate ${repo_name}"; continue; }
  SEEN_REPOS[$repo_name]=1

  # Filter: -c flag
  if [[ -n "$ONLY_REPOS" && -z "${SELECTED_REPOS[$repo_name]:-}" ]]; then
    continue
  fi

  # Filter: -i interactive prompt
  if $INTERACTIVE; then
    read -rp "Process ${repo_name}? [y/n/q] " answer
    case "$answer" in
      q|Q) echo "Quitting."; exit 0 ;;
      y|Y) ;;
      *)   echo "  Skipped"; continue ;;
    esac
  fi

  echo "==> Processing ${ORG}/${repo_name} @ ${BRANCH}"

  if $DRY_RUN; then
    echo "  [dry-run] would clone, update, and PR ${ORG}/${repo_name}"
    continue
  fi

  repo_dir="${WORKDIR}/${repo_name}"
  if ! git clone --depth 1 --branch "$BRANCH" "https://github.com/${ORG}/${repo_name}.git" "$repo_dir" 2>/dev/null; then
    echo "  Branch ${BRANCH} does not exist or clone failed, skipping"
    continue
  fi

  if ! update_dockerfiles "$repo_dir"; then
    echo "  No Dockerfiles updated, skipping PR"
    continue
  fi

  pushd "$repo_dir" > /dev/null
  git checkout -b "$PR_BRANCH"
  git add -A
  if git diff --cached --quiet; then
    echo "  No changes detected (already up to date), skipping"
    popd > /dev/null
    continue
  fi
  git commit -m "Update base image SHAs in .konflux/dockerfiles

Updated GO_BUILDER and/or RUNTIME image digests for ${BRANCH}."

  git push --force origin "$PR_BRANCH"

  pr_body="Automated update of base image SHA digests in \`.konflux/dockerfiles/\` for branch \`${BRANCH}\`."
  if [[ -n "$GO_FULL_REF" ]]; then
    pr_body+=$'\n'"- GO_BUILDER: \`${GO_FULL_REF}\`"
  elif [[ -n "$GO_SHA" ]]; then
    pr_body+=$'\n'"- GO_BUILDER sha256:${GO_SHA:0:12}..."
  fi
  if [[ -n "$RUNTIME_FULL_REF" ]]; then
    pr_body+=$'\n'"- RUNTIME: \`${RUNTIME_FULL_REF}\`"
  elif [[ -n "$RUNTIME_SHA" ]]; then
    pr_body+=$'\n'"- RUNTIME sha256:${RUNTIME_SHA:0:12}..."
  fi

  existing_pr_state=$(gh pr view "$PR_BRANCH" --repo "${ORG}/${repo_name}" --json state -q '.state' 2>/dev/null || true)
  if [[ "$existing_pr_state" == "OPEN" ]]; then
    echo "  ✅ Open PR already exists for ${repo_name}, force-pushed update"
  else
    gh pr create \
      --repo "${ORG}/${repo_name}" \
      --base "$BRANCH" \
      --head "$PR_BRANCH" \
      --title "Update base image SHAs for ${BRANCH}" \
      --body "$pr_body" \
      --label "lgtm" --label "approved" --label "automated"
    echo "  ✅ PR created for ${repo_name}"
  fi
  popd > /dev/null
done

echo "Done!"
