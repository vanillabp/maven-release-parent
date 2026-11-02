#!/usr/bin/env bash
# The shared part of a release train. A release train builds the bundle of every release of
# its repositories and keeps it as an Actions artifact. release-train.yaml then uploads all
# bundles to Maven Central as one deployment. See the README of maven-release-parent.
#
# The release workflows of the other repositories download this file from the main branch
# of maven-release-parent, so the logic exists once.
#
#   release-train.sh prepare <train> <line>
#       In a release build, before the build. Checks the train name and the plugin version,
#       then unpacks the bundles of the train into ~/.m2/repository, so the build finds the
#       versions which are not on Maven Central yet. Its own slot is left out.
#   release-train.sh pack <train> <line> <version>
#       In a release build, after the build. Puts the bundle and a train.json next to each
#       other in $RUNNER_TEMP/release-train, ready for actions/upload-artifact.
#   release-train.sh collect <train> <directory> <max files> <max MB>
#       In release-train.yaml. Unpacks every bundle of the train into <directory>, stops on
#       a file which two bundles both contain, prints a table and checks the limits.
#
# A slot is one release line of one repository. Its artifact is named
# release-train-<train>-<repository>-<line>. The line is 'main', except in the Business
# Cockpit Camunda 8 adapter, which has one line per Camunda version. A slot can be built
# more than once, for example after a fix. The newest build of a slot wins.
#
# Needs GH_TOKEN with 'actions:read' in every repository below.
set -euo pipefail

ORGANIZATION=vanillabp
REPOSITORIES="maven-release-parent spi-for-java adapter-platform-integration
  hazelcast-shared-election-cache business-cockpit businesscockpit-camunda7-adapter
  businesscockpit-camunda8-adapter businesscockpit-cibseven-adapter
  businesscockpit-operaton-adapter businesscockpit-process-engine-api-adapter"
WORK="${RUNNER_TEMP:-/tmp}/release-train-work"

fail() {
  echo "::error::$*" >&2
  exit 1
}

check_train_name() {
  # no dash, so the name of an artifact splits into train, repository and line one way only
  [[ "$1" =~ ^[A-Za-z0-9._]+$ ]] \
    || fail "A train name holds letters, digits, dots and underscores only: '$1'"
}

# Prints one line per slot: repository, line, artifact id, created_at, run id. For each slot
# it is the newest artifact which has not expired.
list_slots() {
  local train=$1 repo prefix
  for repo in $REPOSITORIES; do
    prefix="release-train-$train-$repo-"
    gh api --paginate "repos/$ORGANIZATION/$repo/actions/artifacts?per_page=100" \
      --jq ".artifacts[] | select(.expired | not) | select(.name | startswith(\"$prefix\"))
            | [\"$repo\", (.name | ltrimstr(\"$prefix\")), .id, .created_at, .workflow_run.id]
            | @tsv"
  done | sort -t $'\t' -k4,4r | awk -F '\t' '!seen[$1 FS $2]++' | sort -t $'\t' -k1,1 -k2,2V
}

# Downloads one artifact into a new directory and prints that directory.
download() {
  local repo=$1 line=$2 id=$3 dir="$WORK/$1-$2"
  rm -rf "$dir" && mkdir -p "$dir"
  gh api "repos/$ORGANIZATION/$repo/actions/artifacts/$id/zip" > "$dir.zip"
  unzip -q "$dir.zip" -d "$dir"
  [ -f "$dir/central-bundle.zip" ] || fail "The artifact of $repo, line $line holds no central-bundle.zip"
  echo "$dir"
}

prepare() {
  local train=$1 line=$2
  check_train_name "$train"
  local own="${GITHUB_REPOSITORY#*/}"
  # 'skipUpload' came with central-publishing-maven-plugin 0.12.0. An older plugin would
  # upload this release on its own, so the train stops here.
  mvn --batch-mode --no-transfer-progress --quiet --non-recursive help:effective-pom \
    -P release,central-portal -Doutput="$WORK/effective-pom.xml"
  local plugin
  plugin=$(grep -A1 '<artifactId>central-publishing-maven-plugin</artifactId>' "$WORK/effective-pom.xml" \
    | sed -n 's|.*<version>\(.*\)</version>.*|\1|p' | sort -V | head -1)
  if [ -z "$plugin" ] || [ "$(printf '%s\n' 0.12.0 "$plugin" | sort -V | head -1)" != 0.12.0 ]; then
    fail "central-publishing-maven-plugin '$plugin' cannot keep a bundle without uploading it. A release train needs 0.12.0 or later, which comes with a release-parent newer than 1.3.0."
  fi
  local repo slot id created run dir
  while IFS=$'\t' read -r repo slot id created run; do
    # a new build of this slot replaces the old one, it does not depend on it
    if [ "$repo" = "$own" ] && [ "$slot" = "$line" ]; then
      continue
    fi
    dir=$(download "$repo" "$slot" "$id")
    echo "Unpacking $repo, line $slot, from run $run ($created) into ~/.m2/repository"
    unzip -q -o "$dir/central-bundle.zip" -d "$HOME/.m2/repository"
  done < <(list_slots "$train")
}

pack() {
  local train=$1 line=$2 version=$3 out="${RUNNER_TEMP:-/tmp}/release-train"
  check_train_name "$train"
  mapfile -t bundles < <(find . -path '*/target/central-publishing/central-bundle.zip')
  [ "${#bundles[@]}" = 1 ] \
    || fail "Expected one target/central-publishing/central-bundle.zip, found ${#bundles[@]}: ${bundles[*]:-none}"
  rm -rf "$out" && mkdir -p "$out"
  cp "${bundles[0]}" "$out/central-bundle.zip"
  jq -n --arg repository "${GITHUB_REPOSITORY#*/}" --arg line "$line" --arg version "$version" \
    --arg run "${GITHUB_RUN_ID:-}" --arg commit "$(git rev-parse HEAD)" \
    '{repository: $repository, line: $line, version: $version, run_id: $run, commit: $commit}' \
    > "$out/train.json"
  cat "$out/train.json"
}

collect() {
  local train=$1 target=$2 max_files=$3 max_mb=$4
  check_train_name "$train"
  mkdir -p "$target"
  local table="| Repository | Line | Version | Files | MB | Run | Built at |
|---|---|---|---:|---:|---|---|"
  local repo slot id created run dir version files bytes entry
  local sum_files=0 sum_bytes=0 count=0
  declare -A owner=()
  while IFS=$'\t' read -r repo slot id created run; do
    dir=$(download "$repo" "$slot" "$id")
    version=$(jq -r .version "$dir/train.json" 2>/dev/null || echo "?")
    files=0
    while IFS= read -r entry; do
      case "$entry" in */) continue ;; esac
      if [ -n "${owner[$entry]:-}" ]; then
        fail "Two bundles contain $entry: ${owner[$entry]} and $repo line $slot"
      fi
      owner[$entry]="$repo line $slot"
      files=$((files + 1))
    done < <(unzip -Z1 "$dir/central-bundle.zip")
    bytes=$(unzip -l "$dir/central-bundle.zip" | tail -1 | awk '{print $1}')
    unzip -q "$dir/central-bundle.zip" -d "$target"
    table+=$'\n'"| $repo | $slot | $version | $files | $(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1e6}') | $run | $created |"
    sum_files=$((sum_files + files))
    sum_bytes=$((sum_bytes + bytes))
    count=$((count + 1))
  done < <(list_slots "$train")
  [ "$count" -gt 0 ] || fail "No bundle of the train '$train' was found"
  local sum_mb
  sum_mb=$(awk -v b="$sum_bytes" 'BEGIN{printf "%.2f", b/1e6}')
  table+=$'\n'"| **Sum** | | | **$sum_files** | **$sum_mb** | | |"
  echo "$table"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '## Release train %s\n\n%s\n' "$train" "$table" >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$sum_files" -gt "$max_files" ]; then
    fail "The train has $sum_files files, more than the $max_files which are left this month"
  fi
  if awk -v s="$sum_bytes" -v m="$max_mb" 'BEGIN{exit !(s > m * 1e6)}'; then
    fail "The train has $sum_mb MB, more than the $max_mb MB which are left this month"
  fi
  check_layout "$target"
}

# What Central checks as well, so a broken bundle stops here and not after the upload:
# every directory with files has a POM, and every file has a signature and two checksums.
check_layout() {
  local target=$1 problems=0 dir file
  while IFS= read -r dir; do
    if ! compgen -G "$dir/*.pom" > /dev/null; then
      echo "::error::No .pom in ${dir#"$target"/}" >&2
      problems=$((problems + 1))
    fi
  done < <(find "$target" -type f -printf '%h\n' | sort -u)
  while IFS= read -r file; do
    for suffix in asc md5 sha1; do
      if [ ! -f "$file.$suffix" ]; then
        echo "::error::No .$suffix for ${file#"$target"/}" >&2
        problems=$((problems + 1))
      fi
    done
  done < <(find "$target" -type f ! -name '*.asc' ! -name '*.md5' ! -name '*.sha1' \
             ! -name '*.sha256' ! -name '*.sha512')
  [ "$problems" = 0 ] || fail "The merged bundle has $problems problems, see above"
  echo "Every directory has a .pom, and every file has .asc, .md5 and .sha1."
}

mkdir -p "$WORK"
command=${1:-}
shift || true
case "$command" in
  prepare) [ $# = 2 ] || fail "usage: release-train.sh prepare <train> <line>"; prepare "$@" ;;
  pack) [ $# = 3 ] || fail "usage: release-train.sh pack <train> <line> <version>"; pack "$@" ;;
  collect) [ $# = 4 ] || fail "usage: release-train.sh collect <train> <directory> <max files> <max MB>"; collect "$@" ;;
  *) fail "usage: release-train.sh prepare|pack|collect ..." ;;
esac
