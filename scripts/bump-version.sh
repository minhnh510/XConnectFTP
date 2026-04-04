#!/bin/zsh

set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-XConnectFTP.xcodeproj/project.pbxproj}"

usage() {
  cat <<'EOF'
Usage:
  scripts/bump-version.sh <marketing-version> [build-number]

Examples:
  scripts/bump-version.sh 1.0.3
  scripts/bump-version.sh 1.0.3 1024

Behavior:
  - Updates MARKETING_VERSION in the Xcode project.
  - Updates CURRENT_PROJECT_VERSION in the Xcode project.
  - If build-number is omitted, the current build number is incremented by 1.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$PROJECT_PATH" ]]; then
  echo "Project file not found: $PROJECT_PATH" >&2
  exit 1
fi

new_marketing_version="$1"
if [[ ! "$new_marketing_version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then
  echo "Invalid marketing version: $new_marketing_version" >&2
  echo "Expected formats like 1.0 or 1.0.3" >&2
  exit 1
fi

marketing_versions=("${(@f)$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' "$PROJECT_PATH" | sort -u)}")
build_numbers=("${(@f)$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$PROJECT_PATH" | sort -u)}")

if [[ ${#marketing_versions[@]} -ne 1 ]]; then
  echo "Expected exactly one MARKETING_VERSION value in $PROJECT_PATH, found: ${marketing_versions[*]}" >&2
  exit 1
fi

if [[ ${#build_numbers[@]} -ne 1 ]]; then
  echo "Expected exactly one CURRENT_PROJECT_VERSION value in $PROJECT_PATH, found: ${build_numbers[*]}" >&2
  exit 1
fi

current_marketing_version="${marketing_versions[1]}"
current_build_number="${build_numbers[1]}"

if [[ $# -eq 2 ]]; then
  new_build_number="$2"
else
  if [[ ! "$current_build_number" =~ '^[0-9]+$' ]]; then
    echo "Current build number is not numeric: $current_build_number" >&2
    exit 1
  fi
  new_build_number="$(( current_build_number + 1 ))"
fi

if [[ ! "$new_build_number" =~ '^[0-9]+$' ]]; then
  echo "Invalid build number: $new_build_number" >&2
  exit 1
fi

MARKETING_VERSION="$new_marketing_version" BUILD_NUMBER="$new_build_number" perl -0pi -e '
  s/(MARKETING_VERSION = )[^;]+;/${1}$ENV{MARKETING_VERSION};/g;
  s/(CURRENT_PROJECT_VERSION = )[^;]+;/${1}$ENV{BUILD_NUMBER};/g;
' "$PROJECT_PATH"

echo "Updated $PROJECT_PATH"
echo "MARKETING_VERSION: $current_marketing_version -> $new_marketing_version"
echo "CURRENT_PROJECT_VERSION: $current_build_number -> $new_build_number"
