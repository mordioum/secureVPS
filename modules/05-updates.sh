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

# 2. Mises à jour en 3 phases
echo ""
if [[ "${UPDATES_COUNT}" -gt 0 ]]; then
    log_step "2. Stratégie de mise à jour"
    
    echo ""
    echo -e "${BOLD}3 phases possibles :${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase A (safe)${RESET}    : Tous les paquets non-kernel et non-Docker"
    echo -e "                       ${DIM}Aucune coupure de service${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase B (kernel)${RESET}  : Paquets kernel et headers"
    echo -e "                       ${DIM}Aucune coupure (actif après reboot)${RESET}"
    echo ""
    echo -e "  ${BOLD}Phase C (Docker)${RESET}  : docker-ce et plugins"
    echo -e "                       ${DIM}COUPURE 30s-2min des containers${RESET}"
    echo ""
    
    if ask_yes_no "Procéder aux mises à jour Phase A (safe) ?" "y"; then
        log_step "Phase A - Mises à jour safe"
        
        # Update sans kernel ni docker
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
            --exclude=linux-image-* \
            --exclude=linux-headers-* \
            --exclude=docker-* 2>&1 | tail -10 | sed 's/^/  /' || true
        
        log_success "Phase A terminée"
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
