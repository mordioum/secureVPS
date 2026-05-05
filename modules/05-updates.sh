#!/usr/bin/env bash
# Module 05 : Mises à jour système et configuration unattended-upgrades

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
LIB_DIR="${PROJECT_ROOT}/lib"

# shellcheck source=../lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=../lib/prompts.sh
source "${LIB_DIR}/prompts.sh"

init_logging
require_root

# ═══════════════════════════════════════════════════════════════════
# MAJ SYSTÈME + UNATTENDED-UPGRADES
# ═══════════════════════════════════════════════════════════════════

log_section "MISES À JOUR SYSTÈME & UNATTENDED-UPGRADES"

# 1. État actuel
log_step "1. État actuel des mises à jour"

apt update >/dev/null 2>&1
UPDATES_COUNT="$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)"

echo -e "  ${BOLD}Mises à jour disponibles${RESET} : ${UPDATES_COUNT}"

if [[ "${UPDATES_COUNT}" -eq 0 ]]; then
    log_success "Système déjà à jour"
else
    echo ""
    log_info "Détail des mises à jour disponibles :"
    apt list --upgradable 2>/dev/null | head -20 | sed 's/^/  /'
    
    if [[ "${UPDATES_COUNT}" -gt 20 ]]; then
        echo "  ${DIM}... et $((UPDATES_COUNT - 20)) autres${RESET}"
    fi
fi

# 2. Mises à jour en 3 phases (A → C → B recommandé)
#
# Helpers : hold/unhold un set de patterns dpkg avec cleanup garanti par trap.
# Définis ici pour être partagés entre Phase A, Phase C et Phase B.

# HOLD_BUFFER : array global rempli par apt_hold_pkgs, vidé par apt_unhold_pkgs.
# Permet à la fonction trap de relâcher les paquets même si l'utilisateur Ctrl-C.
HOLD_BUFFER=()

apt_hold_pkgs() {
    # Args : liste de patterns (préfixes de noms de paquets installés).
    # Marque hold chaque paquet correspondant et le pousse dans HOLD_BUFFER.
    local pattern pkg
    for pattern in "$@"; do
        while IFS= read -r pkg; do
            [[ -n "${pkg}" ]] || continue
            if apt-mark hold "${pkg}" >/dev/null 2>&1; then
                HOLD_BUFFER+=("${pkg}")
            fi
        done < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E "^${pattern}" || true)
    done
}

apt_unhold_pkgs() {
    local pkg
    for pkg in "${HOLD_BUFFER[@]}"; do
        apt-mark unhold "${pkg}" >/dev/null 2>&1 || true
    done
    HOLD_BUFFER=()
}

# Compteurs : combien de MAJ par catégorie ? (utilisé pour idempotence)
PHASE_A_COUNT="$(apt list --upgradable 2>/dev/null \
    | grep "upgradable" \
    | grep -vE "^(linux-(image|headers|modules)|docker-|containerd)" \
    | wc -l)"
PHASE_B_COUNT="$(apt list --upgradable 2>/dev/null \
    | grep "upgradable" \
    | grep -E "^(linux-(image|headers|modules))" \
    | wc -l)"
PHASE_C_COUNT="$(apt list --upgradable 2>/dev/null \
    | grep "upgradable" \
    | grep -E "^(docker-|containerd)" \
    | wc -l)"

echo ""
if [[ "${UPDATES_COUNT}" -gt 0 ]]; then
    log_step "2. Stratégie de mise à jour"

    echo ""
    echo -e "${BOLD}3 phases possibles :${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase A (safe)${RESET}    : Paquets non-kernel et non-Docker (${PHASE_A_COUNT} en attente)"
    echo -e "                       ${DIM}Aucune coupure de service${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase C (Docker)${RESET}  : docker-ce et plugins, containerd (${PHASE_C_COUNT} en attente)"
    echo -e "                       ${DIM}COUPURE 30s-2min des containers${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase B (kernel)${RESET}  : Paquets kernel, headers, modules (${PHASE_B_COUNT} en attente)"
    echo -e "                       ${DIM}Aucune coupure à l'install (reboot requis ensuite)${RESET}"
    echo ""

    # ─── Phase A (safe) ─────────────────────────────────────────────────────
    if [[ "${PHASE_A_COUNT}" -eq 0 ]]; then
        log_info "Phase A : déjà à jour (aucun paquet non-kernel/Docker en attente)"
    elif ask_yes_no "Procéder aux mises à jour Phase A (safe) ?" "y"; then
        log_step "Phase A - Mises à jour safe"

        apt_hold_pkgs \
            "linux-image-" "linux-headers-" "linux-modules-" "linux-modules-extra-" \
            "docker-ce" "docker-ce-cli" "docker-buildx-plugin" "docker-compose-plugin" \
            "containerd" "containerd.io"
        trap apt_unhold_pkgs EXIT

        log_info "Paquets temporairement bloqués (kernel + Docker) : ${#HOLD_BUFFER[@]}"

        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" 2>&1 | tail -10 | sed 's/^/  /' || true

        apt_unhold_pkgs
        trap - EXIT

        log_success "Phase A terminée (kernel et Docker laissés intacts)"
    fi

    # ─── Phase C (Docker) ───────────────────────────────────────────────────
    if [[ "${PHASE_C_COUNT}" -gt 0 ]] && [[ "${DOCKER_INSTALLED:-false}" == "true" || -x /usr/bin/docker ]]; then
        echo ""
        log_step "Phase C - Mise à jour Docker (optionnelle)"

        log_warn "Docker upgrade va REDÉMARRER le daemon → tous les containers"
        log_warn "vont être pausés/restartés. Coupure typique : 30s à 2min."
        echo ""
        if command -v docker >/dev/null 2>&1; then
            echo -e "${BOLD}Containers actifs actuellement :${RESET}"
            docker ps --format "  ▸ {{.Names}} ({{.Status}})" 2>/dev/null || echo "  (aucun)"
            echo ""
        fi
        log_warn "Avant de continuer, vérifie :"
        log_warn "  1) Backup DBs récent (sudo vps-backup)"
        log_warn "  2) Heures creuses ou maintenance annoncée"
        log_warn "  3) Aucune session client critique en cours"
        echo ""

        if confirm_critical "Procéder à la Phase C (Docker upgrade, coupure brève) ?"; then
            # Snapshot pré-upgrade (insurance / rollback-friendly)
            SNAPSHOT_PATH="/var/log/vps-secure-pre-phaseC-$(date +%Y%m%d-%H%M%S).log"
            docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' > "${SNAPSHOT_PATH}" 2>/dev/null || true
            log_info "Snapshot pré-upgrade : ${SNAPSHOT_PATH}"

            # Hold kernel pendant la Phase C
            apt_hold_pkgs "linux-image-" "linux-headers-" "linux-modules-" "linux-modules-extra-"
            trap apt_unhold_pkgs EXIT

            log_info "Paquets kernel temporairement bloqués : ${#HOLD_BUFFER[@]}"

            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin 2>&1 \
                | tail -10 | sed 's/^/  /' || true

            apt_unhold_pkgs
            trap - EXIT

            # Vérification post-upgrade
            log_info "Attente 5s pour stabilisation..."
            sleep 5
            echo ""
            echo -e "${BOLD}État containers après upgrade :${RESET}"
            docker ps --format "  ▸ {{.Names}} ({{.Status}})" 2>/dev/null | sed 's/^/  /' || echo "  (impossible de lister)"

            EXPECTED="$(grep -c "Up " "${SNAPSHOT_PATH}" 2>/dev/null || echo 0)"
            ACTUAL="$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)"
            if [[ "${ACTUAL}" -lt "${EXPECTED}" ]]; then
                log_warn "Tous les containers ne sont pas remontés (${ACTUAL}/${EXPECTED})"
                log_warn "Vérifier avec : docker ps -a"
                log_warn "Snapshot pré-upgrade : ${SNAPSHOT_PATH}"
            else
                log_success "Tous les containers actifs (${ACTUAL}/${EXPECTED})"
            fi
            log_success "Phase C terminée"
        else
            log_info "Phase C ignorée"
        fi
    elif [[ "${PHASE_C_COUNT}" -eq 0 ]]; then
        log_info "Phase C : Docker à jour (aucun paquet docker-/containerd en attente)"
    fi

    # ─── Phase B (kernel) ───────────────────────────────────────────────────
    if [[ "${PHASE_B_COUNT}" -eq 0 ]]; then
        log_info "Phase B : kernel à jour (aucun paquet linux-* en attente)"
    else
        echo ""
        log_step "Phase B - Mise à jour kernel (optionnelle)"

        log_warn "Phase B installe le nouveau kernel mais ne reboote PAS automatiquement."
        log_warn "Le kernel actuel reste actif jusqu'à un reboot manuel ou auto (4h)."
        echo ""

        if ask_yes_no "Procéder à la Phase B (kernel + headers, reboot requis ensuite) ?" "n"; then
            log_step "Phase B - Mises à jour kernel"

            # Hold Docker pendant la Phase B
            apt_hold_pkgs \
                "docker-ce" "docker-ce-cli" "docker-buildx-plugin" \
                "docker-compose-plugin" "containerd" "containerd.io"
            trap apt_unhold_pkgs EXIT

            log_info "Paquets Docker temporairement bloqués : ${#HOLD_BUFFER[@]}"

            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::="--force-confdef" \
                -o Dpkg::Options::="--force-confold" \
                linux-image-generic linux-headers-generic 2>&1 \
                | tail -10 | sed 's/^/  /' || true

            apt_unhold_pkgs
            trap - EXIT

            log_success "Phase B terminée (kernel installé mais pas activé)"
            log_warn "Reboot requis pour activer le nouveau kernel"
            if [[ -f /var/run/reboot-required.pkgs ]]; then
                log_info "Paquets nécessitant un reboot :"
                sed 's/^/    ▸ /' /var/run/reboot-required.pkgs
            fi
            log_info "Pour rebooter : sudo reboot"
            log_info "Auto-reboot configuré à 4h du matin (via unattended-upgrades)"
        fi
    fi
fi

# 3. Configuration unattended-upgrades
log_step "3. Configuration des mises à jour automatiques"

# Installer si pas déjà
if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
    log_info "Installation de unattended-upgrades"
    apt install -y unattended-upgrades apt-listchanges
fi

# Configuration auto-upgrades
AUTO_UPGRADES_FILE="/etc/apt/apt.conf.d/20auto-upgrades"

cat > "${AUTO_UPGRADES_FILE}" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
EOF

log_success "Fichier ${AUTO_UPGRADES_FILE} créé"

# Demander si on veut auto-reboot
echo ""
if ask_yes_no "Activer le redémarrage automatique pour les MAJ kernel (4h du matin) ?" "y"; then
    UNATTENDED_FILE="/etc/apt/apt.conf.d/50unattended-upgrades"
    
    # Activer auto-reboot
    if grep -q "^//Unattended-Upgrade::Automatic-Reboot " "${UNATTENDED_FILE}" 2>/dev/null; then
        sed -i 's|^//Unattended-Upgrade::Automatic-Reboot ".*";|Unattended-Upgrade::Automatic-Reboot "true";|' "${UNATTENDED_FILE}"
    elif ! grep -q "^Unattended-Upgrade::Automatic-Reboot " "${UNATTENDED_FILE}" 2>/dev/null; then
        echo 'Unattended-Upgrade::Automatic-Reboot "true";' >> "${UNATTENDED_FILE}"
    fi
    
    if grep -q "^//Unattended-Upgrade::Automatic-Reboot-Time " "${UNATTENDED_FILE}" 2>/dev/null; then
        sed -i 's|^//Unattended-Upgrade::Automatic-Reboot-Time ".*";|Unattended-Upgrade::Automatic-Reboot-Time "04:00";|' "${UNATTENDED_FILE}"
    elif ! grep -q "^Unattended-Upgrade::Automatic-Reboot-Time " "${UNATTENDED_FILE}" 2>/dev/null; then
        echo 'Unattended-Upgrade::Automatic-Reboot-Time "04:00";' >> "${UNATTENDED_FILE}"
    fi
    
    log_success "Auto-reboot activé à 4h du matin"
fi

# Activer le service
systemctl enable unattended-upgrades >/dev/null 2>&1
systemctl restart unattended-upgrades

if systemctl is-active --quiet unattended-upgrades; then
    log_success "Service unattended-upgrades actif"
else
    log_warn "Service unattended-upgrades non actif"
fi

# Test
echo ""
log_info "Test de la configuration"
unattended-upgrade --dry-run --debug 2>&1 | tail -5 | sed 's/^/  /' || true

# Vérification reboot nécessaire
echo ""
if [[ -f /var/run/reboot-required ]]; then
    log_warn "Un redémarrage est nécessaire pour activer un nouveau kernel"
    
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        log_info "Paquets nécessitant un reboot :"
        cat /var/run/reboot-required.pkgs | sed 's/^/  ▸ /'
    fi
    
    echo ""
    log_warn "ATTENTION : reboot = coupure de tous les services"
    log_warn "Pour les serveurs de production, planifier le reboot"
    
    if ask_yes_no "Redémarrer maintenant ?" "n"; then
        log_warn "Redémarrage dans 10 secondes..."
        log_info "Vous serez déconnecté SSH"
        log_info "Reconnectez-vous dans 1-3 minutes"
        sleep 10
        reboot
    else
        log_info "Reboot reporté. Pour redémarrer plus tard : sudo reboot"
    fi
fi

# Récap
log_section "MAJ SYSTÈME CONFIGURÉES"

echo -e "${BOLD}Récapitulatif :${RESET}"
echo -e "  ${CHECK} Système à jour (Phase A)"
echo -e "  ${CHECK} unattended-upgrades configuré"
echo -e "  ${CHECK} MAJ sécurité automatiques activées"
[[ -f /var/run/reboot-required ]] && echo -e "  ${WARN}  Reboot nécessaire" || echo -e "  ${CHECK} Pas de reboot requis"
echo ""

log_info "Commandes utiles :"
echo -e "  ${DIM}sudo apt list --upgradable${RESET}                    # Voir MAJ disponibles"
echo -e "  ${DIM}sudo unattended-upgrade --dry-run --debug${RESET}     # Test config"
echo -e "  ${DIM}cat /var/log/unattended-upgrades/*.log${RESET}        # Logs"
