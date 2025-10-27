
#!/bin/bash

set -eu

# Ensure we're running under bash even if invoked with sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly CONTAINER_NAME="advantech-l2-02"

# Configuration
readonly PROJECT_DIRS="src models data"
readonly XAUTH_FILE="${HOME}/.docker.xauth"  
readonly COMPOSE_TIMEOUT=60

# ANSI color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Logging utilities
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*${NC}" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $*${NC}" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*${NC}" >&2
}

# Error handler
error_handler() {
    local line_no=$1
    log_error "Build script failed at line ${line_no}"
    exit 1
}



display_banner() {
    clear
    echo -e "${RED}"
    cat << 'EOF'
   ██████╗  ██████╗ ████████╗██╗██╗      ██████╗ 
  ██╔════╝ ██╔═══██╗╚══██╔══╝██║██║     ██╔═══██╗
  ██║  ███╗██║   ██║   ██║   ██║██║     ██║   ██║
  ██║   ██║██║   ██║   ██║   ██║██║     ██║   ██║
  ╚██████╔╝╚██████╔╝   ██║   ██║███████╗╚██████╔╝
   ╚═════╝  ╚═════╝    ╚═╝   ╚═╝╚══════╝ ╚═════╝ 
EOF
    echo -e "${WHITE}                          See Beyond Vision${NC}"
    echo
    echo -e "${CYAN}Launching Gotilo Systems...${NC}\n"
    sleep 2
}
# Check command availability
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Verify prerequisites
check_prerequisites() {
    log "Verifying prerequisites..."
    
    local missing_deps=""
    
    # Check Docker
    if ! command_exists docker; then
        missing_deps="${missing_deps} docker"
    fi
    
    # Check Docker Compose
    if ! command_exists docker-compose && ! (command_exists docker && docker compose version >/dev/null 2>&1); then
        missing_deps="${missing_deps} docker-compose"
    fi

    if ! command_exists xhost; then
        log_warning "xhost not found - X11 forwarding may not work properly"
    fi
    
    # Check JetPack installation
    if ! apt show nvidia-jetpack >/dev/null 2>&1; then
        log_warning "NVIDIA JetPack not detected - GPU acceleration may not be available"
    else
        log_success "NVIDIA JetPack detected"
    fi
    
    if [ -n "$missing_deps" ]; then
        log_error "Missing required dependencies:$missing_deps"
        log_error "Please install the missing dependencies and try again"
        return 1
    fi
    
    # Verify Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    # Check NVIDIA runtime
    if ! docker info 2>/dev/null | grep -q nvidia; then
        log_warning "NVIDIA Docker runtime not detected - GPU acceleration may not work"
    fi
    
    log_success "Prerequisites verified"
    return 0
}

start_containers() {
    log "Starting Docker containers..."
    
    # Locate compose file (support common names)
    local compose_file=""
    for f in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
            compose_file="${SCRIPT_DIR}/${f}"
            break
        fi
    done
    if [[ -z "${compose_file}" ]]; then
        log_error "No Docker Compose file found in ${SCRIPT_DIR} (looked for docker-compose.yml/.yaml and compose.yml/.yaml)"
        return 1
    fi
    
    # Determine compose command
    local compose_cmd
    if command_exists docker-compose; then
        compose_cmd="docker-compose"
    elif command_exists docker && docker compose version &>/dev/null; then
        compose_cmd="docker compose"
    else
        log_error "No valid Docker Compose command found"
        return 1
    fi
    
    # Determine container name (prefer value from compose file if set)
    local container="${CONTAINER_NAME}"
    local parsed_name
    parsed_name=$(grep -E '^[[:space:]]*container_name:[[:space:]]*' "${compose_file}" | head -n1 | sed -E 's/^[[:space:]]*container_name:[[:space:]]*//') || true
    if [[ -n "${parsed_name}" ]]; then
        container="${parsed_name}"
    fi

    # Stop existing containers if running
    if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        log "Stopping existing container..."
        ${compose_cmd} -f "${compose_file}" down --timeout "${COMPOSE_TIMEOUT}" || true
    fi
    
    # Build and start containers
    log "Building and starting container with ${compose_cmd}..."
    if ! ${compose_cmd} -f "${compose_file}" up --build -d --timeout "${COMPOSE_TIMEOUT}"; then
        log_error "Failed to start containers"
        ${compose_cmd} -f "${compose_file}" logs --tail=50 || true
        return 1
    fi
    
    # Wait for container to be healthy
    log "Waiting for container to be ready..."
    local retries=60
    local ready=0
    while (( retries > 0 )); do
        # If healthcheck exists, wait for healthy
        local health
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${container}" 2>/dev/null || echo "")
        if [[ -n "${health}" ]]; then
            if [[ "${health}" == "healthy" ]]; then
                log_success "Container is healthy"
                ready=1
                break
            fi
        else
            # Fallback: ensure container is running and responsive
            if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
                if docker exec "${container}" true &>/dev/null; then
                    log_success "Container is running"
                    ready=1
                    break
                fi
            fi
        fi
        sleep 2
        ((retries--))
    done

    if (( ready == 0 )); then
        log_error "Container failed to become ready"
        return 1
    fi

    # Block until container stops
    log "Container is running. Waiting for it to stop..."
    while docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null | grep -q true; do
        sleep 2
    done

    local exit_code
    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "${container}" 2>/dev/null || echo "")
    if [[ -n "${exit_code}" ]]; then
        if [[ "${exit_code}" == "0" ]]; then
            log_success "Container stopped cleanly (exit code 0)"
            return 0
        else
            log_error "Container stopped (exit code ${exit_code})"
            return "${exit_code}"
        fi
    else
        log_warning "Container stopped; exit code unknown"
        return 0
    fi
}

main() {
    display_banner
    check_prerequisites || exit 1
    start_containers
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        log_success "Container lifecycle completed successfully."
    else
        log_error "Container exited with code $rc"
    fi
    exit $rc
    
  
}

# Execute main function
main "$@"