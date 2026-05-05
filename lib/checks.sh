#!/usr/bin/env bash
# Vérifications système (root, OS, etc.)
# Source: source lib/checks.sh

# Vérifie qu'on est root
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Ce script doit être exécuté en root (ou avec sudo)"
        log_info "Relancez avec : sudo $0 $*"
        exit 1
    fi
}

# Détecte la version d'Ubuntu
detect_ubuntu_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Impossible de détecter l'OS (/etc/os-release manquant)"
        exit 1
    fi
    
    # shellcheck disable=SC1091
    source /etc/os-release
    
    if [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *"debian"* ]]; then
        log_warn "Ce script est conçu pour Ubuntu (détecté: ${ID:-inconnu})"
        log_warn "Il peut fonctionner sur Debian mais sans garantie"
    fi
    
    UBUNTU_VERSION="${VERSION_ID:-unknown}"
    UBUNTU_CODENAME="${VERSION_CODENAME:-unknown}"
    
    log_info "Système détecté : ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
    log_info "Kernel : $(uname -r)"
    
    case "${UBUNTU_VERSION}" in
        22.04|24.04|26.04)
            log_success "Version supportée : ${UBUNTU_VERSION}"
            ;;
        20.04)
            log_warn "Ubuntu 20.04 : support partiel, prudence recommandée"
            ;;
        *)
            log_warn "Version Ubuntu non testée : ${UBUNTU_VERSION}"
            log_warn "Le script peut fonctionner mais aucune garantie"
            ;;
    esac
    
    export UBUNTU_VERSION
    export UBUNTU_CODENAME
}

# Détecte si SSH utilise socket activation (Ubuntu 24+/26+)
detect_ssh_socket_activation() {
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        SSH_SOCKET_ACTIVATION="true"
        log_info "SSH utilise socket activation (systemd)"
    else
        SSH_SOCKET_ACTIVATION="false"
        log_info "SSH utilise le service classique"
    fi
    export SSH_SOCKET_ACTIVATION
}

# Détecte la présence de Tailscale
detect_tailscale() {
    if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
        TAILSCALE_INSTALLED="true"
        TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -1)"
        log_success "Tailscale détecté (IP: ${TAILSCALE_IP:-inconnue})"
    else
        TAILSCALE_INSTALLED="false"
        TAILSCALE_IP=""
        log_info "Tailscale non détecté"
    fi
    export TAILSCALE_INSTALLED
    export TAILSCALE_IP
}

# Détecte la présence de Docker
detect_docker() {
    if command -v docker >/dev/null 2>&1; then
        DOCKER_INSTALLED="true"
        DOCKER_VERSION="$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
        DOCKER_CONTAINERS_COUNT="$(docker ps -q 2>/dev/null | wc -l)"
        log_info "Docker détecté : version ${DOCKER_VERSION}"
        log_info "Containers actifs : ${DOCKER_CONTAINERS_COUNT}"
        
        # Détection Docker Swarm
        if docker info 2>/dev/null | grep -q "Swarm: active"; then
            DOCKER_SWARM="true"
            log_info "Docker Swarm actif"
        else
            DOCKER_SWARM="false"
        fi
    else
        DOCKER_INSTALLED="false"
        DOCKER_VERSION=""
        DOCKER_CONTAINERS_COUNT="0"
        DOCKER_SWARM="false"
        log_info "Docker non installé"
    fi
    export DOCKER_INSTALLED DOCKER_VERSION DOCKER_CONTAINERS_COUNT DOCKER_SWARM
}

# Détecte UFW
detect_ufw() {
    if command -v ufw >/dev/null 2>&1; then
        UFW_INSTALLED="true"
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            UFW_ACTIVE="true"
            log_info "UFW installé et actif"
        else
            UFW_ACTIVE="false"
            log_info "UFW installé mais inactif"
        fi
    else
        UFW_INSTALLED="false"
        UFW_ACTIVE="false"
        log_info "UFW non installé"
    fi
    export UFW_INSTALLED UFW_ACTIVE
}

# Détecte fail2ban
# `systemctl list-unit-files | grep` était fragile (B11) — on teste plutôt
# is-active directement (vérité absolue), avec fallbacks sur fail2ban-client
# et le fichier de service systemd.
detect_fail2ban() {
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        FAIL2BAN_INSTALLED="true"
        FAIL2BAN_ACTIVE="true"
        log_info "Fail2ban installé et actif"
    elif command -v fail2ban-client >/dev/null 2>&1 \
        || [[ -f /lib/systemd/system/fail2ban.service ]] \
        || [[ -f /etc/systemd/system/fail2ban.service ]]; then
        FAIL2BAN_INSTALLED="true"
        FAIL2BAN_ACTIVE="false"
        log_info "Fail2ban installé mais inactif"
    else
        FAIL2BAN_INSTALLED="false"
        FAIL2BAN_ACTIVE="false"
        log_info "Fail2ban non installé"
    fi
    export FAIL2BAN_INSTALLED FAIL2BAN_ACTIVE
}

# Vérifie si un port est en écoute
is_port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -qE ":${port}\s"
}

# Vérifie si un user existe
user_exists() {
    local user="$1"
    id "${user}" >/dev/null 2>&1
}

# Vérifie si un user a le sudo
user_has_sudo() {
    local user="$1"
    groups "${user}" 2>/dev/null | grep -qE '\bsudo\b'
}

# Récupère l'IP publique du VPS
get_public_ip() {
    local ip=""
    
    # Essayer plusieurs services pour fiabilité
    for service in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
        ip="$(curl -s -4 --max-time 5 "${service}" 2>/dev/null || echo "")"
        if [[ -n "${ip}" ]] && [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done
    
    echo "unknown"
    return 1
}

# Valide qu'une IP IPv4 est correcte (chaque octet entre 0 et 255)
is_valid_ipv4() {
    local ip="$1"
    [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}"
    (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 ))
}

# Valide qu'un nom d'utilisateur est correct
is_valid_username() {
    local user="$1"
    [[ "${user}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]
}

# Valide qu'un port est correct
is_valid_port() {
    local port="$1"
    [[ "${port}" =~ ^[0-9]+$ ]] && [[ "${port}" -ge 1 ]] && [[ "${port}" -le 65535 ]]
}
