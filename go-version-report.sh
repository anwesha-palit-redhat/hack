#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -b BRANCH1,BRANCH2,...

Generate a Markdown report of Go versions across all downstream repos.

Required:
  -b BRANCHES      Comma-separated release branches (e.g. release-v1.24.x,release-v1.23.x,release-v1.15.x)

Optional:
  -d REPOS_DIR     Path to config/downstream/repos (default: config/downstream/repos)
  -o ORG           GitHub org (default: openshift-pipelines)
  -f OUTPUT        Output file (default: go-version-report.md)
  -h               Show this help
EOF
  exit 1
}

BRANCHES_CSV=""
REPOS_DIR="config/downstream/repos"
ORG="openshift-pipelines"
OUTPUT="go-version-report.md"

while getopts "b:d:o:f:h" opt; do
  case $opt in
    b) BRANCHES_CSV="$OPTARG" ;;
    d) REPOS_DIR="$OPTARG" ;;
    o) ORG="$OPTARG" ;;
    f) OUTPUT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

[[ -z "$BRANCHES_CSV" ]] && { echo "ERROR: -b BRANCHES is required"; usage; }

IFS=',' read -ra BRANCHES <<< "$BRANCHES_CSV"

get_repo_name() {
  local file="$1"
  local repo
  repo=$(sed -n 's/^repo: *//p' "$file" | head -1)
  if [[ -z "$repo" ]]; then
    repo=$(sed -n 's/^name: *//p' "$file" | head -1)
  fi
  echo "$repo"
}

declare -A SEEN_REPOS
REPOS=()
for yaml_file in "$REPOS_DIR"/*.yaml; do
  base=$(basename "$yaml_file" .yaml)
  [[ "$base" == operator-index* || "$base" == console-plugin* ]] && continue
  repo_name=$(get_repo_name "$yaml_file")
  [[ -z "$repo_name" ]] && continue
  [[ -n "${SEEN_REPOS[$repo_name]:-}" ]] && continue
  SEEN_REPOS[$repo_name]=1
  REPOS+=("$repo_name")
done

IFS=$'\n' REPOS=($(printf '%s\n' "${REPOS[@]}" | sort)); unset IFS

echo "Fetching Go versions for ${#REPOS[@]} repos across ${#BRANCHES[@]} branches..."

declare -A RESULTS
for repo in "${REPOS[@]}"; do
  for branch in "${BRANCHES[@]}"; do
    version="N/A"
    for path in upstream/go.mod go.mod; do
      url="https://raw.githubusercontent.com/${ORG}/${repo}/${branch}/${path}"
      tmpfile=$(mktemp)
      if curl -sf "$url" -o "$tmpfile" 2>/dev/null; then
        v=$(sed -n 's/^go  *\([^ ]*\).*/\1/p' "$tmpfile" | head -1)
        if [[ -n "$v" ]]; then
          version="$v"
          rm -f "$tmpfile"
          break
        fi
      fi
      rm -f "$tmpfile"
    done
    RESULTS["${repo}|${branch}"]="$version"
    echo "  ${repo} @ ${branch}: ${version}"
  done
done

# Generate markdown
{
  echo "# Go Version Report — OpenShift Pipelines"
  echo ""
  echo "> Generated on $(date '+%Y-%m-%d %H:%M %Z')"
  echo ""

  # Summary stats
  all_versions=()
  mismatch_repos=()
  na_repos=()
  for repo in "${REPOS[@]}"; do
    versions=()
    all_na=true
    for branch in "${BRANCHES[@]}"; do
      v="${RESULTS["${repo}|${branch}"]}"
      if [[ "$v" != "N/A" ]]; then
        versions+=("$v")
        all_versions+=("$v")
        all_na=false
      fi
    done
    if $all_na; then
      na_repos+=("$repo")
    elif [[ ${#versions[@]} -gt 1 ]]; then
      unique=$(printf '%s\n' "${versions[@]}" | sort -u | wc -l | tr -d ' ')
      [[ "$unique" -gt 1 ]] && mismatch_repos+=("$repo")
    fi
  done
  unique_total=$(printf '%s\n' "${all_versions[@]}" | sort -u | wc -l | tr -d ' ')

  echo "## Summary"
  echo ""
  echo "| Metric | Value |"
  echo "|--------|-------|"
  echo "| Total repos | ${#REPOS[@]} |"
  echo "| Distinct Go versions | ${unique_total} |"
  echo "| Repos with version mismatch | ${#mismatch_repos[@]} |"
  echo "| Repos without go.mod | ${#na_repos[@]} |"
  echo ""

  if [[ ${#mismatch_repos[@]} -gt 0 ]]; then
    echo "> **Warning:** ${#mismatch_repos[@]} repo(s) have different Go versions across branches: ${mismatch_repos[*]}"
    echo ""
  fi

  # Main table
  echo "## Go Versions by Repository"
  echo ""
  header="| Repository |"
  separator="|------------|"
  for branch in "${BRANCHES[@]}"; do
    short="${branch#release-}"
    header+=" ${short} |"
    separator+="--------|"
  done
  header+=" Mismatch? |"
  separator+="-----------|"
  echo "$header"
  echo "$separator"

  for repo in "${REPOS[@]}"; do
    row="| \`${repo}\` |"
    versions=()
    for branch in "${BRANCHES[@]}"; do
      v="${RESULTS["${repo}|${branch}"]}"
      row+=" ${v} |"
      [[ "$v" != "N/A" ]] && versions+=("$v")
    done
    if [[ ${#versions[@]} -eq 0 ]]; then
      row+=" - |"
    elif [[ ${#versions[@]} -eq 1 ]]; then
      row+=" No |"
    else
      unique=$(printf '%s\n' "${versions[@]}" | sort -u | wc -l | tr -d ' ')
      if [[ "$unique" -gt 1 ]]; then
        row+=" **Yes** |"
      else
        row+=" No |"
      fi
    fi
    echo "$row"
  done
  echo ""

  # NA repos
  if [[ ${#na_repos[@]} -gt 0 ]]; then
    echo "## Repos Without go.mod"
    echo ""
    for r in "${na_repos[@]}"; do
      echo "- \`${r}\`"
    done
    echo ""
  fi
} > "$OUTPUT"

echo ""
echo "Report written to ${OUTPUT}"
