#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

BINARY_ARCHIVE=${ROOT_DIR}/bin/bitcoin-binaries.tar.gz
BINARY_CHECKSUM_FILE=${BINARY_ARCHIVE}.sha256
CORE_IMAGE_OVERRIDE=${CORE_IMAGE:-}
NODE_IMAGE_TAG_OVERRIDE=${NODE_IMAGE_TAG:-}
BINARY_SHA256=
BINARY_ARCHITECTURE=
BINARY_VERSION=
SOURCE_REPOSITORY=
SOURCE_SHA256=
SOURCE_REVISION=
CORE_IMAGE=
NODE_IMAGE_TAG=
TIMEOUT_SECONDS=600
BOOTSTRAP_TIMEOUT_SECONDS=900
BOOTSTRAP_TARGET_HEIGHT=200
REBUILD_CORE=0
REBUILD_NODES=0
SCENARIO_ID=
PROJECT_NAME=
ACTIVE_NODES=
RESOURCE_PROFILE="3 GB/node, 24 GB total; 93.75 GiB/node transient tmpfs ceiling"
COMPOSE_FILES=(-f compose.yaml)
SERVICES=()
CLEANUP_DONE=0
LOGS_SAVED=0
RUN_DATETIME=
declare -A CONTAINER_IDS=()
declare -A BOOTSTRAP_PROGRESS_LINES=()

##
# @brief Prints command usage.
##
usage() {
  cat <<USAGE
Usage:
  ./run.sh SCENARIO [options]
  ./run.sh --list

Options:
  --rebuild-core          Rebuild the runtime core image from the supplied
                          binary artifact without Docker cache.
  --rebuild-nodes         Rebuild selected node images without cache.
  --list                  List scenario numbers and selected nodes.
  -h, --help              Show this help.
USAGE
}

##
# @brief Prints a timestamped runner message.
# @param ... Message text.
##
log() {
  printf '%s [runner] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

##
# @brief Lists scenario numbers and the nodes selected by each.
##
list_scenarios() {
  local file base scenario node
  declare -A scenario_nodes=()
  shopt -s nullglob
  for file in scenarios/node??_scenario*.sh; do
    base=$(basename "$file")
    if [[ "$base" =~ ^node(0[1-8])_scenario([0-9]+)\.sh$ ]]; then
      node="node${BASH_REMATCH[1]}"
      scenario=${BASH_REMATCH[2]}
      scenario_nodes[$scenario]="${scenario_nodes[$scenario]:-} ${node}"
    fi
  done
  if [[ ${#scenario_nodes[@]} -eq 0 ]]; then
    printf 'No scenarios found.\n'
    return
  fi
  while IFS= read -r scenario; do
    printf 'scenario %-4s nodes:%s\n' "$scenario" "${scenario_nodes[$scenario]}"
  done < <(printf '%s\n' "${!scenario_nodes[@]}" | sort -n)
}

##
# @brief Calculates one selected node's contiguous bootstrap block range.
# @param $1 Target block count.
# @param $2 Zero-based selected-node position.
# @param $3 Selected-node count.
# @return Prints start height, block count, and end height.
##
calculate_bootstrap_range() {
  local target=$1
  local position=$2
  local node_count=$3
  local base remainder earlier_extras count start end

  base=$((target / node_count))
  remainder=$((target % node_count))
  earlier_extras=$position
  if (( earlier_extras > remainder )); then
    earlier_extras=$remainder
  fi
  count=$base
  if (( position < remainder )); then
    count=$((count + 1))
  fi
  start=$((position * base + earlier_extras + 1))
  end=$((start + count - 1))
  printf '%d %d %d\n' "$start" "$count" "$end"
}

##
# @brief Resolves and validates the binary artifact identity used by every node.
# @return Zero when the artifact and its provenance are valid.
##
prepare_binary_identity() {
  local archive_dir checksum_name short_sha members required

  if [[ ! -f "$BINARY_ARCHIVE" || ! -f "$BINARY_CHECKSUM_FILE" ]]; then
    printf 'Copy bitcoin-binaries.tar.gz and bitcoin-binaries.tar.gz.sha256 into bin/.\n' >&2
    return 1
  fi

  archive_dir=$(dirname "$BINARY_ARCHIVE")
  checksum_name=$(basename "$BINARY_CHECKSUM_FILE")
  if ! (cd "$archive_dir" && sha256sum --check --strict --status "$checksum_name"); then
    printf 'Binary artifact checksum validation failed.\n' >&2
    return 1
  fi

  members=$(tar -tzf "$BINARY_ARCHIVE")
  if printf '%s\n' "$members" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    printf 'Binary artifact contains an unsafe path.\n' >&2
    return 1
  fi
  for required in \
    checksums.sha256 \
    usr/local/bin/bitcoin \
    usr/local/bin/bitcoind \
    usr/local/bin/bitcoin-cli \
    usr/local/bin/bitcoin-tx \
    usr/local/bin/bitcoin-util \
    usr/local/bin/bitcoin-wallet \
    opt/bitcoin/COPYING \
    opt/bitcoin/SOURCE_REPOSITORY \
    opt/bitcoin/SOURCE_SHA256 \
    opt/bitcoin/SOURCE_REVISION \
    opt/bitcoin/ARCHITECTURE \
    opt/bitcoin/VERSION; do
    if ! printf '%s\n' "$members" | grep -Fxq "$required"; then
      printf 'Binary artifact is missing %s.\n' "$required" >&2
      return 1
    fi
  done

  BINARY_SHA256=$(sha256sum "$BINARY_ARCHIVE" | awk '{print $1}')
  SOURCE_REPOSITORY=$(tar -xOf "$BINARY_ARCHIVE" opt/bitcoin/SOURCE_REPOSITORY | tr -d '[:space:]')
  SOURCE_SHA256=$(tar -xOf "$BINARY_ARCHIVE" opt/bitcoin/SOURCE_SHA256 | tr -d '[:space:]')
  SOURCE_REVISION=$(tar -xOf "$BINARY_ARCHIVE" opt/bitcoin/SOURCE_REVISION | tr -d '[:space:]')
  BINARY_ARCHITECTURE=$(tar -xOf "$BINARY_ARCHIVE" opt/bitcoin/ARCHITECTURE | tr -d '[:space:]')
  BINARY_VERSION=$(tar -xOf "$BINARY_ARCHIVE" opt/bitcoin/VERSION | head -n 1)

  if [[ ! "$BINARY_SHA256" =~ ^[0-9a-f]{64}$ \
        || ! "$SOURCE_SHA256" =~ ^[0-9a-f]{64}$ \
        || ! "$SOURCE_REPOSITORY" =~ ^[A-Za-z0-9._-]+$ \
        || "$SOURCE_REPOSITORY" == "." \
        || "$SOURCE_REPOSITORY" == ".." \
        || -z "$SOURCE_REVISION" \
        || ! "$BINARY_ARCHITECTURE" =~ ^(amd64|arm64)$ \
        || -z "$BINARY_VERSION" ]]; then
    printf 'Binary artifact provenance is invalid.\n' >&2
    return 1
  fi

  short_sha=${BINARY_SHA256:0:16}
  CORE_IMAGE=${CORE_IMAGE_OVERRIDE:-bitcoin-env/core-source:${short_sha}}
  NODE_IMAGE_TAG=${NODE_IMAGE_TAG_OVERRIDE:-source-${short_sha}}
}

##
# @brief Verifies that the runtime core image contains the supplied binaries.
# @return Zero when binary provenance and executable checks pass without networking.
##
verify_core_image_binaries() {
  docker run --rm --network none \
    --env "EXPECTED_BINARY_SHA256=${BINARY_SHA256}" \
    --env "EXPECTED_SOURCE_SHA256=${SOURCE_SHA256}" \
    --env "EXPECTED_SOURCE_REVISION=${SOURCE_REVISION}" \
    --env "EXPECTED_ARCHITECTURE=${BINARY_ARCHITECTURE}" \
    --entrypoint /bin/bash \
    "$CORE_IMAGE" -Eeuo pipefail -c '
      for binary in bitcoin bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
        command -v "$binary" >/dev/null
      done
      test "$BITCOIN_BINARY_SHA256" = "$EXPECTED_BINARY_SHA256"
      test "$BITCOIN_SOURCE_SHA256" = "$EXPECTED_SOURCE_SHA256"
      test "$BITCOIN_SOURCE_REVISION" = "$EXPECTED_SOURCE_REVISION"
      test "$BITCOIN_ARCHITECTURE" = "$EXPECTED_ARCHITECTURE"
      test "$(cat /opt/bitcoin/BINARY_ARCHIVE_SHA256)" = "$EXPECTED_BINARY_SHA256"
      test "$(cat /opt/bitcoin/SOURCE_SHA256)" = "$EXPECTED_SOURCE_SHA256"
      test "$(cat /opt/bitcoin/SOURCE_REVISION)" = "$EXPECTED_SOURCE_REVISION"
      test "$(cat /opt/bitcoin/ARCHITECTURE)" = "$EXPECTED_ARCHITECTURE"
    '
}

##
# @brief Runs Docker Compose with the selected project and files.
# @param ... Docker Compose arguments.
##
compose() {
  docker compose --project-name "$PROJECT_NAME" "${COMPOSE_FILES[@]}" "$@"
}

##
# @brief Stops every selected container while preserving it for log collection.
##
stop_selected_containers() {
  local service cid
  local -a container_ids=()

  [[ -n "$PROJECT_NAME" ]] || return 0
  for service in "${SERVICES[@]}"; do
    cid=${CONTAINER_IDS[$service]:-}
    if [[ -z "$cid" ]]; then
      cid=$(compose ps --all --quiet "$service" 2>/dev/null || true)
    fi
    [[ -n "$cid" ]] && container_ids+=("$cid")
  done

  if [[ ${#container_ids[@]} -gt 0 ]]; then
    log "Stopping selected containers before exporting their logs"
    docker stop -t 30 "${container_ids[@]}" >/dev/null 2>&1 || true
  fi
}

##
# @brief Exports each selected container's complete stdout and stderr to logs/.
##
save_node_logs() {
  local service cid output_file

  if [[ "$LOGS_SAVED" -eq 1 ]]; then
    return 0
  fi
  LOGS_SAVED=1
  [[ -n "$PROJECT_NAME" && -n "$SCENARIO_ID" && -n "$RUN_DATETIME" ]] || return 0

  mkdir -p "$ROOT_DIR/logs"
  for service in "${SERVICES[@]}"; do
    cid=${CONTAINER_IDS[$service]:-}
    if [[ -z "$cid" ]]; then
      cid=$(compose ps --all --quiet "$service" 2>/dev/null || true)
    fi
    [[ -n "$cid" ]] || continue

    output_file="$ROOT_DIR/logs/${service}_scenario${SCENARIO_ID}_${RUN_DATETIME}.log"
    if docker logs "$cid" >"$output_file" 2>&1; then
      log "Saved ${service} logs to ${output_file#$ROOT_DIR/}"
    else
      printf 'Could not read Docker logs for container %s.\n' "$cid" >"$output_file"
      log "Created ${output_file#$ROOT_DIR/}, but Docker could not return the container logs"
    fi
  done
}

##
# @brief Removes containers, transient tmpfs state, and the scenario network.
# @return Exits with the status active when cleanup began.
##
cleanup() {
  local exit_status=$?
  if [[ "$CLEANUP_DONE" -eq 1 ]]; then
    return
  fi
  CLEANUP_DONE=1
  trap - EXIT
  set +e
  if [[ -n "$PROJECT_NAME" ]]; then
    stop_selected_containers
    save_node_logs
    log "Removing scenario containers, network, and transient tmpfs state"
    compose down --remove-orphans --volumes >/dev/null 2>&1 || true
  fi
  exit "$exit_status"
}

##
# @brief Checks whether a file exists inside a running container.
# @param $1 Container ID.
# @param $2 Absolute container path.
##
container_file_exists() {
  local cid=$1
  local path=$2
  if docker exec "$cid" test -f "$path" >/dev/null 2>&1; then
    return 0
  fi
  docker cp "${cid}:${path}" - 2>/dev/null | tar -tf - >/dev/null 2>&1
}

##
# @brief Reads a file from a running container.
# @param $1 Container ID.
# @param $2 Absolute container path.
##
container_file_read() {
  local cid=$1
  local path=$2
  if docker exec "$cid" cat "$path" 2>/dev/null; then
    return 0
  fi
  docker cp "${cid}:${path}" - 2>/dev/null | tar -xOf - 2>/dev/null
}

##
# @brief Reads one value from a KEY=value state file in a container.
# @param $1 Container ID.
# @param $2 Key name.
##
container_state_value() {
  local cid=$1
  local key=$2
  container_file_read "$cid" /run/bitcoin-env/initial-state.env \
    | awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}'
}

##
# @brief Prints bootstrap progress lines that have not yet been shown by the runner.
# @param $1 Service name.
# @param $2 Container ID.
##
print_bootstrap_progress() {
  local service=$1
  local cid=$2
  local progress_file=/run/bitcoin-env/bootstrap-progress.log
  local content current_count printed_count start_line

  if ! container_file_exists "$cid" "$progress_file"; then
    return 0
  fi

  content=$(container_file_read "$cid" "$progress_file" 2>/dev/null || true)
  current_count=$(printf '%s\n' "$content" | awk 'NF {count++} END {print count + 0}')
  printed_count=${BOOTSTRAP_PROGRESS_LINES[$service]:-0}
  if (( current_count <= printed_count )); then
    return 0
  fi

  start_line=$((printed_count + 1))
  printf '%s\n' "$content" | awk -v start="$start_line" 'NF {line++; if (line >= start) print}'
  BOOTSTRAP_PROGRESS_LINES[$service]=$current_count
}

##
# @brief Writes the shared scenario start epoch into a container.
# @param $1 Container ID.
# @param $2 Unix epoch.
##
release_container_scenario() {
  local cid=$1
  local epoch=$2
  docker exec "$cid" bash -c 'printf "%s\n" "$1" > /run/bitcoin-env/scenario.start' _ "$epoch"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-core)
      REBUILD_CORE=1
      shift
      ;;
    --rebuild-nodes)
      REBUILD_NODES=1
      shift
      ;;
    --list)
      list_scenarios
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$SCENARIO_ID" ]]; then
        printf 'Only one scenario number may be supplied.\n' >&2
        exit 2
      fi
      SCENARIO_ID=$1
      shift
      ;;
  esac
done

if [[ -z "$SCENARIO_ID" || ! "$SCENARIO_ID" =~ ^[0-9]+$ ]]; then
  usage >&2
  exit 2
fi
shopt -s nullglob
scenario_files=(scenarios/node??_scenario"${SCENARIO_ID}".sh)
if [[ ${#scenario_files[@]} -eq 0 ]]; then
  printf 'No files match scenarios/nodeXX_scenario%s.sh\n' "$SCENARIO_ID" >&2
  list_scenarios >&2
  exit 3
fi

for file in "${scenario_files[@]}"; do
  base=$(basename "$file")
  if [[ ! "$base" =~ ^node(0[1-8])_scenario${SCENARIO_ID}\.sh$ ]]; then
    printf 'Invalid scenario filename: %s\n' "$base" >&2
    exit 3
  fi
  SERVICES+=("node${BASH_REMATCH[1]}")
  bash -n "$file"
done
mapfile -t SERVICES < <(printf '%s\n' "${SERVICES[@]}" | sort -u)
ACTIVE_NODES=$(IFS=,; printf '%s' "${SERVICES[*]}")

for command_name in docker tar awk sort sha256sum grep dirname basename; do
  command -v "$command_name" >/dev/null 2>&1 || { printf '%s is required.\n' "$command_name" >&2; exit 4; }
done
docker compose version >/dev/null 2>&1 || { printf 'Docker Compose v2 is required.\n' >&2; exit 4; }
docker info >/dev/null 2>&1 || { printf 'Docker Engine is not reachable.\n' >&2; exit 4; }
prepare_binary_identity

PROJECT_NAME="bitcoin-env-s${SCENARIO_ID}-$$-${RANDOM}"
export CORE_IMAGE NODE_IMAGE_TAG SCENARIO_ID ACTIVE_NODES
export BOOTSTRAP_TARGET_HEIGHT BOOTSTRAP_TIMEOUT_SECONDS
export BITCOIN_SOURCE_REPOSITORY="$SOURCE_REPOSITORY"
export BITCOIN_SOURCE_SHA256="$SOURCE_SHA256"
export BITCOIN_SOURCE_REVISION="$SOURCE_REVISION"
export BITCOIN_BINARY_SHA256="$BINARY_SHA256"
export BITCOIN_ARCHITECTURE="$BINARY_ARCHITECTURE"

log "Using ${RESOURCE_PROFILE}"
log "Using bin/bitcoin-binaries.tar.gz; archive SHA-256: ${BINARY_SHA256}"
log "Compiled source: ${SOURCE_REPOSITORY}; source SHA-256: ${SOURCE_SHA256}; revision: ${SOURCE_REVISION}"
log "Scenario ${SCENARIO_ID} selects only: ${ACTIVE_NODES}"
log "Every selected node starts empty and mines one sequential share of heights 1-${BOOTSTRAP_TARGET_HEIGHT}"
compose config --quiet

log "Building runtime core image ${CORE_IMAGE} from the supplied Bitcoin binary artifact"
core_build=(
  docker build
  --file docker/Dockerfile.core
  --tag "$CORE_IMAGE"
  --build-arg "BITCOIN_SOURCE_REPOSITORY=${SOURCE_REPOSITORY}"
  --build-arg "BITCOIN_SOURCE_SHA256=${SOURCE_SHA256}"
  --build-arg "BITCOIN_SOURCE_REVISION=${SOURCE_REVISION}"
  --build-arg "BITCOIN_BINARY_SHA256=${BINARY_SHA256}"
  --build-arg "BITCOIN_ARCHITECTURE=${BINARY_ARCHITECTURE}"
)
if [[ "$REBUILD_CORE" -eq 1 ]]; then
  core_build+=(--no-cache)
fi
core_build+=(.)
"${core_build[@]}"
verify_core_image_binaries

log "Building ${#SERVICES[@]} distinct runtime-bootstrap node image(s)"
if [[ "$REBUILD_NODES" -eq 1 ]]; then
  compose build --no-cache "${SERVICES[@]}"
else
  compose build "${SERVICES[@]}"
fi

RUN_DATETIME=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$ROOT_DIR/logs"
log "Launching selected nodes on the internal-only Docker network"
compose up --detach --no-build --remove-orphans "${SERVICES[@]}"

for service in "${SERVICES[@]}"; do
  cid=$(compose ps --quiet "$service")
  if [[ -z "$cid" ]]; then
    log "No container ID was created for ${service}"
    log "Per-node logs will be exported during cleanup"
    exit 5
  fi
  CONTAINER_IDS[$service]=$cid
  BOOTSTRAP_PROGRESS_LINES[$service]=0
done

expected_memory=3221225472
expected_data_tmpfs_size=100629741568
expected_run_tmpfs_size=16777216
expected_tmp_tmpfs_size=16777216
for service in "${SERVICES[@]}"; do
  cid=${CONTAINER_IDS[$service]}
  actual_memory=$(docker inspect --format '{{.HostConfig.Memory}}' "$cid")
  actual_swap=$(docker inspect --format '{{.HostConfig.MemorySwap}}' "$cid")
  actual_nano_cpus=$(docker inspect --format '{{.HostConfig.NanoCpus}}' "$cid")
  read_only_root=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$cid")
  data_tmpfs=$(docker inspect --format '{{range .HostConfig.Mounts}}{{if eq .Target "/data"}}{{.Type}} {{.TmpfsOptions.SizeBytes}}{{end}}{{end}}' "$cid")
  run_tmpfs=$(docker inspect --format '{{range .HostConfig.Mounts}}{{if eq .Target "/run"}}{{.Type}} {{.TmpfsOptions.SizeBytes}}{{end}}{{end}}' "$cid")
  temp_tmpfs=$(docker inspect --format '{{range .HostConfig.Mounts}}{{if eq .Target "/tmp"}}{{.Type}} {{.TmpfsOptions.SizeBytes}}{{end}}{{end}}' "$cid")
  network_id=$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$cid")
  network_internal=false
  [[ -z "$network_id" ]] || network_internal=$(docker network inspect --format '{{.Internal}}' "$network_id")
  if [[ "$actual_memory" != "$expected_memory" || "$actual_swap" != "$expected_memory" || "$actual_nano_cpus" != "1000000000" ]]; then
    log "Docker did not apply the expected CPU/memory limits to ${service}"
    exit 5
  fi
  if [[ "$read_only_root" != "true" \
        || "$data_tmpfs" != "tmpfs ${expected_data_tmpfs_size}" \
        || "$run_tmpfs" != "tmpfs ${expected_run_tmpfs_size}" \
        || "$temp_tmpfs" != "tmpfs ${expected_tmp_tmpfs_size}" ]]; then
    log "Docker did not apply the read-only root or transient tmpfs limits to ${service}"
    exit 5
  fi
  if [[ -z "$network_id" || "$network_internal" != "true" ]]; then
    log "Docker did not apply the internal-network setting to ${service}"
    exit 5
  fi
done

log "Generating the first ${BOOTSTRAP_TARGET_HEIGHT} blocks; one progress line will be printed for every block"
bootstrap_deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_SECONDS ))
last_ready=-1
while :; do
  ready=0
  for service in "${SERVICES[@]}"; do
    cid=${CONTAINER_IDS[$service]}
    print_bootstrap_progress "$service" "$cid"
    if container_file_exists "$cid" /run/bitcoin-env/initial-state.ready; then
      ready=$((ready + 1))
      continue
    fi
    running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null || printf 'false')
    if [[ "$running" != "true" ]]; then
      log "${service} exited during initial-chain generation"
      log "Per-node logs will be exported during cleanup"
      exit 6
    fi
  done
  if (( ready != last_ready )); then
    log "Initial-chain readiness: ${ready}/${#SERVICES[@]} node(s)"
    last_ready=$ready
  fi
  (( ready == ${#SERVICES[@]} )) && break
  if (( $(date +%s) > bootstrap_deadline )); then
    log "Timed out after ${BOOTSTRAP_TIMEOUT_SECONDS}s generating the initial chain"
    log "Per-node logs will be exported during cleanup"
    exit 7
  fi
  sleep 0.25
done

for service in "${SERVICES[@]}"; do
  print_bootstrap_progress "$service" "${CONTAINER_IDS[$service]}"
done

reference_hash=
reference_source_sha256=
reference_source_revision=
printf '\n===== Initial 200-block state reached =====\n'
printf 'chain:       private custom Signet\n'
printf 'height:      %s\n' "$BOOTSTRAP_TARGET_HEIGHT"
printf 'nodes:       %s\n' "$ACTIVE_NODES"
printf 'network:     Docker internal network only\n'
printf 'internet:    disabled for running nodes\n'
printf 'generation:\n'
for index in "${!SERVICES[@]}"; do
  service=${SERVICES[$index]}
  cid=${CONTAINER_IDS[$service]}
  chain=$(container_state_value "$cid" CHAIN)
  height=$(container_state_value "$cid" HEIGHT)
  hash=$(container_state_value "$cid" TIP_HASH)
  active_node_count=$(container_state_value "$cid" ACTIVE_NODE_COUNT)
  mined_from=$(container_state_value "$cid" MINED_FROM)
  mined_to=$(container_state_value "$cid" MINED_TO)
  mined_blocks=$(container_state_value "$cid" MINED_BLOCKS)
  wallet=$(container_state_value "$cid" WALLET)
  source_sha256=$(container_state_value "$cid" SOURCE_SHA256)
  source_revision=$(container_state_value "$cid" SOURCE_REVISION)
  read -r expected_from expected_count expected_to \
    < <(calculate_bootstrap_range "$BOOTSTRAP_TARGET_HEIGHT" "$index" "${#SERVICES[@]}")

  if [[ "$chain" != "signet" || "$height" != "$BOOTSTRAP_TARGET_HEIGHT" || ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
    log "${service} reported an invalid initial-chain network, height, or hash"
    exit 7
  fi
  if [[ "$active_node_count" != "${#SERVICES[@]}" || -z "$wallet" ]]; then
    log "${service} reported invalid initial-chain participation metadata"
    exit 7
  fi
  if [[ ! "$source_sha256" =~ ^[0-9a-f]{64}$ || -z "$source_revision" ]]; then
    log "${service} reported invalid compiled-source metadata"
    exit 7
  fi
  if [[ -z "$reference_source_sha256" ]]; then
    reference_source_sha256=$source_sha256
    reference_source_revision=$source_revision
  elif [[ "$source_sha256" != "$reference_source_sha256" || "$source_revision" != "$reference_source_revision" ]]; then
    log "Selected nodes do not use the same compiled source build"
    exit 7
  fi
  if [[ "$SOURCE_SHA256" =~ ^[0-9a-f]{64}$ && "$source_sha256" != "$SOURCE_SHA256" ]]; then
    log "${service} source identity does not match the supplied binary artifact"
    exit 7
  fi
  if [[ "$mined_from" != "$expected_from" || "$mined_to" != "$expected_to" || "$mined_blocks" != "$expected_count" ]]; then
    log "${service} reported an unexpected bootstrap range"
    exit 7
  fi
  if [[ -z "$reference_hash" ]]; then
    reference_hash=$hash
  elif [[ "$hash" != "$reference_hash" ]]; then
    log "Selected nodes do not agree on the height-${BOOTSTRAP_TARGET_HEIGHT} block hash"
    exit 7
  fi
  printf '  %-6s heights %3s-%-3s  blocks=%-3s wallet=%s\n' "$service" "$mined_from" "$mined_to" "$mined_blocks" "$wallet"
done
printf 'tip hash:    %s\n' "$reference_hash"
printf 'binaries:    supplied by build environment (%s)\n' "$SOURCE_REPOSITORY"
printf 'source hash: %s\n' "$reference_source_sha256"
printf 'revision:    %s\n' "$reference_source_revision"
printf 'status:      initial 200-block state reached on all selected nodes\n'
printf '=============================================\n'
printf 'INITIAL_200_BLOCK_STATE_REACHED chain=signet height=%s tip=%s nodes=%s\n\n' \
  "$BOOTSTRAP_TARGET_HEIGHT" "$reference_hash" "$ACTIVE_NODES"
log "Initial 200-block state has been reached; proceeding with test scenario ${SCENARIO_ID}"

scenario_epoch=$(( $(date +%s) + 5 ))
log "Releasing scenario ${SCENARIO_ID} on all nodes at epoch ${scenario_epoch}"
for service in "${SERVICES[@]}"; do
  release_container_scenario "${CONTAINER_IDS[$service]}" "$scenario_epoch"
done

log "Waiting for every selected node to finish its scenario"
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
last_completed=-1
while :; do
  completed=0
  for service in "${SERVICES[@]}"; do
    cid=${CONTAINER_IDS[$service]}
    if container_file_exists "$cid" /run/bitcoin-env/scenario.done; then
      completed=$((completed + 1))
      continue
    fi
    running=$(docker inspect --format '{{.State.Running}}' "$cid" 2>/dev/null || printf 'false')
    if [[ "$running" != "true" ]]; then
      log "${service} exited before writing its scenario result"
      log "Per-node logs will be exported during cleanup"
      exit 6
    fi
  done
  if (( completed != last_completed )); then
    log "Scenario completion: ${completed}/${#SERVICES[@]} node(s)"
    last_completed=$completed
  fi
  (( completed == ${#SERVICES[@]} )) && break
  if (( $(date +%s) > deadline )); then
    log "Timed out after ${TIMEOUT_SECONDS}s waiting for scenario ${SCENARIO_ID}"
    log "Per-node logs will be exported during cleanup"
    exit 7
  fi
  sleep 1
done

overall_status=0
for service in "${SERVICES[@]}"; do
  cid=${CONTAINER_IDS[$service]}
  status=$(container_file_read "$cid" /run/bitcoin-env/scenario.status 2>/dev/null || printf '125')
  status=${status//$'\n'/}
  if [[ ! "$status" =~ ^[0-9]+$ || "$status" != "0" ]]; then
    log "${service} reported scenario status ${status:-unreadable}"
    overall_status=1
  else
    log "${service} reported success"
  fi
done

if [[ "$overall_status" -ne 0 ]]; then
  log "Scenario ${SCENARIO_ID} failed"
  exit 8
fi
log "Scenario ${SCENARIO_ID} passed on ${ACTIVE_NODES}; runtime-generated initial hash=${reference_hash}"
