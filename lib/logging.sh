#!/usr/bin/env bash
# Système de logs structurés
# Source: source lib/logging.sh

# Variables globales
LOG_FILE="${LOG_FILE:-/var/log/vps-secure-$(date +%Y%m%d-%H%M%S).log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARN, ERROR

# S'assurer que le fichier de log existe
init_logging() {
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    
    if [[ ! -d "${log_dir}" ]]; then
        mkdir -p "${log_dir}" 2>/dev/null || {
            # Fallback vers /tmp si pas de droits
            LOG_FILE="/tmp/vps-secure-$(date +%Y%m%d-%H%M%S).log"
        }
    fi
    
    touch "${LOG_FILE}" 2>/dev/null || {
        LOG_FILE="/tmp/vps-secure-$(date +%Y%m%d-%H%M%S).log"
        touch "${LOG_FILE}"
    }
    
    chmod 600 "${LOG_FILE}" 2>/dev/null || true
    
    log_info "════════════════════════════════════════════════════════════"
    log_info "VPS-Secure - Démarrage du log"
    log_info "Date: $(date)"
    log_info "Hostname: $(hostname)"
    log_info "User: $(whoami)"
    log_info "════════════════════════════════════════════════════════════"
}

# Fonction de log générique
_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Toujours écrire dans le fichier
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

log_debug() {
    _log "DEBUG" "$@"
    [[ "${LOG_LEVEL}" == "DEBUG" ]] && echo -e "${DIM}[DEBUG]${RESET} $*" >&2
}

log_info() {
    _log "INFO" "$@"
    echo -e "${BLUE}${INFO}${RESET} $*"
}

log_success() {
    _log "SUCCESS" "$@"
    echo -e "${GREEN}${CHECK}${RESET} $*"
}

log_warn() {
    _log "WARN" "$@"
    echo -e "${YELLOW}${WARN}${RESET}  $*" >&2
}

log_error() {
    _log "ERROR" "$@"
    echo -e "${RED}${CROSS}${RESET} $*" >&2
}

log_step() {
    _log "STEP" "$@"
    echo ""
    echo -e "${CYAN}${BOLD}━━━ $* ━━━${RESET}"
    echo ""
}

log_section() {
    _log "SECTION" "$@"
    echo ""
    echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
    printf "${MAGENTA}${BOLD}║${RESET}  %-60s ${MAGENTA}${BOLD}║${RESET}\n" "$*"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}
