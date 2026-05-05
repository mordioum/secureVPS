#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# DOCKER-INSTALL
# Installation Docker + Dokploy (optionnel) sur Ubuntu
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=lib/prompts.sh
source "${LIB_DIR}/prompts.sh"

init_logging
require_root

log_section "INSTALLATION DOCKER"

detect_ubuntu_version
detect_docker

# Si Docker déjà installé
if [[ "${DOCKER_INSTALLED}" == "true" ]]; then
    log_success "Docker ${DOCKER_VERSION} déjà installé"
    
    if ask_yes_no "Mettre à jour Docker à la dernière version ?" "n"; then
        log_step "Mise à jour Docker"
        apt update -qq
        apt install --only-upgrade -y \
            docker-ce docker-ce-cli docker-ce-rootless-extras \
            docker-buildx-plugin docker-compose-plugin
        log_success "Docker mis à jour"
        docker --version
    fi
else
    # Installation propre
    log_step "Installation des dépendances"
    apt update -qq
    apt install -y ca-certificates curl gnupg
    
    log_step "Ajout du repo officiel Docker"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
        tee /etc/apt/sources.list.d/docker.list >/dev/null
    
    log_step "Installation Docker"
    apt update -qq
    apt install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin
    
    systemctl enable docker
    systemctl start docker
    
    log_success "Docker installé : $(docker --version)"
fi

# Ajouter user au groupe docker
echo ""
NEW_USER="${NEW_USER:-mor}"
if user_exists "${NEW_USER}"; then
    if groups "${NEW_USER}" | grep -q docker; then
        log_info "${NEW_USER} déjà dans le groupe docker"
    else
        if ask_yes_no "Ajouter '${NEW_USER}' au groupe docker (peut lancer docker sans sudo) ?" "y"; then
            usermod -aG docker "${NEW_USER}"
            log_success "${NEW_USER} ajouté au groupe docker"
            log_warn "L'utilisateur doit se déconnecter/reconnecter pour appliquer"
        fi
    fi
fi

# Test
log_step "Test Docker"
docker run --rm hello-world 2>&1 | tail -10 | sed 's/^/  /'

# Dokploy ?
echo ""
if ask_yes_no "Installer Dokploy (PaaS auto-hébergé sur Docker) ?" "n"; then
    log_step "Installation de Dokploy"
    
    PUBLIC_IP="$(get_public_ip || echo "unknown")"
    
    log_info "IP publique détectée : ${PUBLIC_IP}"
    log_info "Dokploy sera accessible sur http://${PUBLIC_IP}:3000"
    echo ""
    
    if ask_yes_no "Continuer avec cette IP ?" "y"; then
        # Mode Swarm requis
        if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
            docker swarm init --advertise-addr "${PUBLIC_IP}" 2>&1 | tail -5
        fi

        # Avertissement avant `curl | bash` non vérifié
        log_warn "L'installer Dokploy va être téléchargé puis exécuté en root :"
        log_warn "  curl -sSL https://dokploy.com/install.sh | bash"
        log_warn "Aucune signature ni checksum n'est vérifiée. Vous faites confiance"
        log_warn "à dokploy.com (HTTPS uniquement) pour le contenu du script."
        echo ""
        if ! ask_yes_no "Confirmer le téléchargement et l'exécution du script Dokploy ?" "y"; then
            log_info "Installation Dokploy annulée. Pour la lancer manuellement plus tard :"
            log_info "  curl -sSL https://dokploy.com/install.sh -o /tmp/dokploy.sh"
            log_info "  less /tmp/dokploy.sh   # inspecter avant"
            log_info "  bash /tmp/dokploy.sh"
            exit 0
        fi

        # Installation officielle
        curl -sSL https://dokploy.com/install.sh | bash

        log_success "Dokploy installé"
        log_info "Accédez à : http://${PUBLIC_IP}:3000"
    fi
fi

log_section "DOCKER PRÊT"
echo -e "  ${CHECK} Docker : $(docker --version)"
echo -e "  ${CHECK} Compose : $(docker compose version 2>/dev/null | head -1)"
echo ""
