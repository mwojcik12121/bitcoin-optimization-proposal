#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

SOURCE_ROOT=${ROOT_DIR}/sources
SOURCE_REPOSITORY=${BITCOIN_SOURCE_REPOSITORY:-bitcoin}
BITCOIN_BUILD_JOBS=${BITCOIN_BUILD_JOBS:-1}
OUTPUT_DIR=${ROOT_DIR}/bin
REBUILD=0
STAGING_DIR=

##
# @brief Prints command usage.
##
usage() {
  cat <<USAGE
Usage:
  ./run.sh [--source-repository NAME] [--build-jobs N] [--rebuild]

Build options:
  --source-repository NAME  Repository directory below sources/ (default: ${SOURCE_REPOSITORY}).
  --build-jobs N            Parallel compile jobs (default: ${BITCOIN_BUILD_JOBS}).
  --rebuild                 Build without Docker cache.
  -h, --help                Show this help.
USAGE
}

##
# @brief Removes the temporary local-export directory.
##
cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}

##
# @brief Prints a source-validation error.
# @param ... Error message.
##
source_error() {
  printf 'source validation failed: %s\n' "$*" >&2
}

##
# @brief Validates one repository directory name.
# @param $1 Repository name.
# @return Zero for a safe single directory name.
##
validate_repository_name() {
  local repository=$1
  [[ "$repository" =~ ^[A-Za-z0-9._-]+$ && "$repository" != "." && "$repository" != ".." ]]
}

##
# @brief Validates the required Bitcoin source-tree files.
# @param $1 Source-root directory.
# @param $2 Bitcoin repository name below the source root.
##
validate_bitcoin_source() {
  local source_root=$1
  local repository=$2
  local repository_dir
  local required

  if ! validate_repository_name "$repository"; then
    source_error "invalid repository name: ${repository}"
    return 1
  fi

  repository_dir=${source_root}/${repository}
  if [[ ! -d "$repository_dir" ]]; then
    source_error "missing repository directory: ${repository_dir}"
    return 1
  fi

  for required in \
    CMakeLists.txt COPYING cmake src/CMakeLists.txt src/bitcoin.cpp src/bitcoind.cpp \
    src/bitcoin-cli.cpp src/bitcoin-tx.cpp src/bitcoin-util.cpp src/bitcoin-wallet.cpp; do
    if [[ ! -e "${repository_dir}/${required}" ]]; then
      source_error "${repository_dir} is missing ${required}"
      return 1
    fi
  done
}

##
# @brief Lists source files included in the aggregate identity.
# @param $1 Source-root directory.
##
list_source_identity_paths() {
  local source_root=$1
  (
    cd "$source_root"
    find . -mindepth 2 \( -type f -o -type l \) \
      ! -path '*/.git/*' \
      ! -path '*/build/*' \
      ! -path '*/build-*/*' \
      ! -path '*/cmake-build-*/*' \
      ! -path '*/depends/built/*' \
      ! -path '*/depends/work/*' \
      ! -path '*/depends/sources/*' \
      ! -name '*.o' \
      ! -name '*.a' \
      ! -name '*.so' \
      ! -name '*.dylib' \
      ! -name '*.dll' \
      -print0 | sort -z
  )
}

##
# @brief Calculates the aggregate SHA-256 for all repository inputs.
# @param $1 Source-root directory.
##
bitcoin_sources_sha256() {
  local source_root=$1

  (
    cd "$source_root"
    list_source_identity_paths . \
      | tar \
          --create \
          --file=- \
          --format=gnu \
          --no-recursion \
          --mtime='UTC 1970-01-01' \
          --owner=0 \
          --group=0 \
          --numeric-owner \
          --null \
          --files-from=-
  ) | sha256sum | awk '{print $1}'
}

##
# @brief Returns the selected repository revision and dirty-state suffix.
# @param $1 Selected repository directory.
##
bitcoin_source_revision() {
  local repository_dir=$1
  local revision=unversioned

  if command -v git >/dev/null 2>&1 \
      && git -C "$repository_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    revision=$(git -C "$repository_dir" rev-parse --short=12 HEAD)
    if [[ -n "$(git -C "$repository_dir" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
      revision=${revision}-dirty
    fi
  fi

  printf '%s\n' "$revision"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-repository)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SOURCE_REPOSITORY=$2
      shift 2
      ;;
    --build-jobs)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      BITCOIN_BUILD_JOBS=$2
      shift 2
      ;;
    --rebuild)
      REBUILD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! validate_repository_name "$SOURCE_REPOSITORY"; then
  printf 'Source repository must be one safe directory name below sources/: %s\n' "$SOURCE_REPOSITORY" >&2
  exit 2
fi

if [[ ! "$BITCOIN_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Build jobs must be a positive integer.\n' >&2
  exit 2
fi

for command_name in docker tar sha256sum awk find sort xargs; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf '%s is required.\n' "$command_name" >&2
    exit 4
  }
done

docker info >/dev/null 2>&1 || {
  printf 'Docker Engine is not reachable.\n' >&2
  exit 4
}

validate_bitcoin_source "$SOURCE_ROOT" "$SOURCE_REPOSITORY"
SOURCE_SHA256=$(bitcoin_sources_sha256 "$SOURCE_ROOT")
SOURCE_REVISION=$(bitcoin_source_revision "${SOURCE_ROOT}/${SOURCE_REPOSITORY}")

if [[ ! "$SOURCE_SHA256" =~ ^[0-9a-f]{64}$ || -z "$SOURCE_REVISION" ]]; then
  printf 'Could not determine valid source provenance.\n' >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"
STAGING_DIR=$(mktemp -d "${OUTPUT_DIR}/.bitcoin-binariesXXXXXX")

build_command=(
  docker build
  --file docker/Dockerfile.core
  --target binaries
  --output "type=local,dest=${STAGING_DIR}"
  --build-arg "BITCOIN_SOURCE_REPOSITORY=${SOURCE_REPOSITORY}"
  --build-arg "BITCOIN_SOURCE_SHA256=${SOURCE_SHA256}"
  --build-arg "BITCOIN_SOURCE_REVISION=${SOURCE_REVISION}"
  --build-arg "BITCOIN_BUILD_JOBS=${BITCOIN_BUILD_JOBS}"
)

if [[ "$REBUILD" -eq 1 ]]; then
  build_command+=(--no-cache)
fi

build_command+=(.)
DOCKER_BUILDKIT=1 "${build_command[@]}"

if [[ "$(bitcoin_sources_sha256 "$SOURCE_ROOT")" != "$SOURCE_SHA256" ]]; then
  printf 'Source files changed during compilation. Run the build again.\n' >&2
  exit 4
fi

required_files=(
  checksums.sha256
  usr/local/bin/bitcoin
  usr/local/bin/bitcoind
  usr/local/bin/bitcoin-cli
  usr/local/bin/bitcoin-tx
  usr/local/bin/bitcoin-util
  usr/local/bin/bitcoin-wallet
  opt/bitcoin/COPYING
  opt/bitcoin/SOURCE_REPOSITORY
  opt/bitcoin/SOURCE_SHA256
  opt/bitcoin/SOURCE_REVISION
  opt/bitcoin/ARCHITECTURE
  opt/bitcoin/VERSION
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "${STAGING_DIR}/${required_file}" ]]; then
    printf 'Build output is missing %s.\n' "$required_file" >&2
    exit 4
  fi
done

(
  cd "$STAGING_DIR"
  sha256sum --check --strict --status checksums.sha256
)

archive=${OUTPUT_DIR}/bitcoin-binaries.tar.gz
archive_checksum=${archive}.sha256
temporary_archive=${archive}.tmp
rm -f -- "$temporary_archive"

tar \
  --sort=name \
  --mtime='UTC 1970-01-01' \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -C "$STAGING_DIR" \
  -czf "$temporary_archive" \
  checksums.sha256 usr opt

mv -f -- "$temporary_archive" "$archive"
(
  cd "$OUTPUT_DIR"
  sha256sum "$(basename "$archive")" > "$(basename "$archive_checksum")"
)

printf 'Build finished successfully: %s\n' "${archive#$ROOT_DIR/}"
