#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

SOURCE_ROOT=${ROOT_DIR}/src
SOURCE_REPOSITORY=${BITCOIN_SOURCE_REPOSITORY:-bitcoin}
BITCOIN_BUILD_JOBS=${BITCOIN_BUILD_JOBS:-1}
OUTPUT_DIR=${ROOT_DIR}/bin
REBUILD=0
STAGING_DIR=

usage() {
  cat <<USAGE
Usage:
  ./build.sh [--bitcoin NAME] [--build-jobs N] [--rebuild]

Build options:
  --bitcoin NAME  Repository directory below src/ (default: ${SOURCE_REPOSITORY}).
  --build-jobs N  Parallel compile jobs (default: ${BITCOIN_BUILD_JOBS}).
  --rebuild       Build without Docker cache.
USAGE
}

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}

source_error() {
  printf 'source validation failed: %s\n' "$*" >&2
}

validate_repository_name() {
  local repository=$1
  [[ "$repository" =~ ^[A-Za-z0-9._-]+$ && "$repository" != "." && "$repository" != ".." ]]
}

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
    --bitcoin)
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
  printf 'Source repository must be one safe directory name below src/: %s\n' "$SOURCE_REPOSITORY" >&2
  exit 2
fi

if [[ ! "$BITCOIN_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Build jobs must be a positive integer.\n' >&2
  exit 2
fi

for command_name in docker tar; do
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
SOURCE_REVISION=$(bitcoin_source_revision "${SOURCE_ROOT}/${SOURCE_REPOSITORY}")
if [[ -z "$SOURCE_REVISION" ]]; then
  printf 'Could not determine the source revision.\n' >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"
STAGING_DIR=$(mktemp -d "${OUTPUT_DIR}/.bitcoin-binariesXXXXXX")

build_command=(
  docker build
  --file Dockerfile.core
  --target binaries
  --output "type=local,dest=${STAGING_DIR}"
  --build-arg "BITCOIN_SOURCE_REPOSITORY=${SOURCE_REPOSITORY}"
  --build-arg "BITCOIN_SOURCE_REVISION=${SOURCE_REVISION}"
  --build-arg "BITCOIN_BUILD_JOBS=${BITCOIN_BUILD_JOBS}"
)

if [[ "$REBUILD" -eq 1 ]]; then
  build_command+=(--no-cache)
fi

build_command+=(.)
DOCKER_BUILDKIT=1 "${build_command[@]}"

required_files=(
  usr/local/bin/bitcoin
  usr/local/bin/bitcoind
  usr/local/bin/bitcoin-cli
  usr/local/bin/bitcoin-tx
  usr/local/bin/bitcoin-util
  usr/local/bin/bitcoin-wallet
  opt/bitcoin/COPYING
  opt/bitcoin/SOURCE_REPOSITORY
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

archive=${OUTPUT_DIR}/bitcoin-binaries.tar.gz
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
  usr opt

mv -f -- "$temporary_archive" "$archive"
printf 'Build finished successfully: %s\n' "${archive#$ROOT_DIR/}"
