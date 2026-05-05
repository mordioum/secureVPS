#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
# VPS-SECURE
# Script de sécurisation universel pour VPS Ubuntu (22.04, 24.04, 26.04)
# 
# Auteur : Mor Dioum
# Version : 1.0.0
# Repo : https://github.com/mordioum/secureVPS (à créer)
# ═══════════════════════════════════════════════════════════════════
#
# Usage interactif :
#   sudo ./vps-secure.sh
#
# Usage avec paramètres :
#   sudo ./vps-secure.sh --user mor --port 2222 --ip 196.207.227.109 \
#                        --mode production
#
# Modules individuels :
#   sudo ./modules/00-audit.sh        # Audit seul
#   sudo ./modules/01-create-user.sh  # User seul
#   sudo ./modules/02-ssh-harden.sh   # SSH seul
#   sudo ./modules/03-fail2ban.sh     # Fail2ban seul
#   sudo ./modules/04-ufw.sh          # UFW seul
#   sudo ./modules/05-updates.sh      # MAJ seules
#
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# Récupérer le chemin du script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
MODULES_DIR="${SCRIPT_DIR}/modules"

# Charger les libs
# shellcheck source=lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=lib/checks.sh
source "${LIB_DIR}/checks.sh"
# shellcheck source=lib/prompts.sh
source "${LIB_DIR}/prompts.sh"

show_help() {
    cat << EOF
VPS-SECURE - Sécurisation universelle pour VPS Ubuntu

Usage: sudo $0 [OPTIONS]

Options principales:
  --user USERNAME       Nom de l'utilisateur non-root à créer
  --port PORT           Port SSH secondaire (défaut: 2222)
  --ip IP               Votre IP publique pour whitelist fail2ban
  --pubkey "KEY"        Clé SSH publique à autoriser
  --mode MODE           Mode UFW: strict|web|production (défaut: production)

Options de skip (utilisation modulaire):
  --skip-audit          Sauter l'audit initial
  --skip-user           Sauter la création d'utilisateur
  --skip-ssh            Sauter le durcissement SSH
  --skip-fail2ban       Sauter fail2ban
  --skip-ufw            Sauter UFW
  --skip-updates        Sauter les MAJ système

Autres:
  --dry-run             Simuler sans rien modifier
  -h, --help            Afficher cette aide

Exemples:
  # Mode interactif (recommandé pour la 1ère fois)
  sudo $0

  # Mode automatisé pour production
  sudo $0 --user mor --port 2222 --ip 196.207.227.109 --mode production

  # Audit seulement (lecture seule, ne change rien)
  sudo $0 --skip-user --skip-ssh --skip-fail2ban --skip-ufw --skip-updates

  # Tout sauf les MAJ (pour faire les MAJ plus tard)
  sudo $0 --user mor --skip-updates

EOF
}

# Détection précoce de --help / -h : doit pouvoir s'afficher sans sudo
for arg in "$@"; do
    case "${arg}" in
        -h|--help) show_help; exit 0 ;;
    esac
done

# Initialisation
init_logging
require_root

# ═══════════════════════════════════════════════════════════════════
# PARSING DES ARGUMENTS
# ═══════════════════════════════════════════════════════════════════

NEW_USER=""
SSH_NEW_PORT="2222"
ADMIN_IP=""
UFW_MODE=""
SSH_PUBKEY=""
SKIP_AUDIT=false
SKIP_USER=false
SKIP_SSH=false
SKIP_FAIL2BAN=false
SKIP_UFW=false
SKIP_UPDATES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) NEW_USER="$2"; shift 2 ;;
        --port) SSH_NEW_PORT="$2"; shift 2 ;;
        --ip) ADMIN_IP="$2"; shift 2 ;;
        --pubkey) SSH_PUBKEY="$2"; shift 2 ;;
        --mode) UFW_MODE="$2"; shift 2 ;;
        --skip-audit) SKIP_AUDIT=true; shift ;;
        --skip-user) SKIP_USER=true; shift ;;
        --skip-ssh) SKIP_SSH=true; shift ;;
        --skip-fail2ban) SKIP_FAIL2BAN=true; shift ;;
        --skip-ufw) SKIP_UFW=true; shift ;;
        --skip-updates) SKIP_UPDATES=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) log_error "Option inconnue : $1"; show_help; exit 1 ;;
    esac
done

# Export pour les modules
export NEW_USER
export SSH_NEW_PORT
export ADMIN_IP
export SSH_PUBKEY
export UFW_MODE
export DRY_RUN

# ═══════════════════════════════════════════════════════════════════
# BANNIÈRE D'ACCUEIL
# ═══════════════════════════════════════════════════════════════════

clear
cat << 'EOF'
 _    ______  _____   _____                       
| |  / / __ \/ ___/  / ___/___  _______  __________
| | / / /_/ /\__ \   \__ \/ _ \/ ___/ / / / ___/ _ \
| |/ / ____/___/ /  ___/ /  __/ /__/ /_/ / /  /  __/
|___/_/    /____/  /____/\___/\___/\__,_/_/   \___/ 
                                                     
                                                     v1.0.0
EOF

echo ""
echo -e "${CYAN}${BOLD}Sécurisation universelle pour VPS Ubuntu${RESET}"
echo -e "${DIM}Compatible Ubuntu 22.04, 24.04, 26.04${RESET}"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    log_warn "MODE DRY-RUN : aucune modification ne sera appliquée"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════
# DÉTECTIONS GLOBALES
# ═══════════════════════════════════════════════════════════════════

log_section "DÉTECTION DE L'ENVIRONNEMENT"

detect_ubuntu_version
detect_ssh_socket_activation
detect_tailscale
detect_docker
detect_ufw
detect_fail2ban

# Détecter l'IP publique automatiquement
if [[ -z "${ADMIN_IP}" ]]; then
    # get_public_ip peut retourner 1 si pas d'internet — sous set -e, il faut neutraliser
    DETECTED_IP="$(get_public_ip || echo "unknown")"
    log_info "IP publique du VPS détectée : ${DETECTED_IP}"
    log_info "(Cette IP est celle du VPS, pas la vôtre)"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉCAPITULATIF DU PLAN
# ═══════════════════════════════════════════════════════════════════

echo ""
log_section "PLAN DE SÉCURISATION"

PLAN_STEPS=()
[[ "${SKIP_AUDIT}" == "false" ]] && PLAN_STEPS+=("0. Audit initial du système")
[[ "${SKIP_USER}" == "false" ]] && PLAN_STEPS+=("1. Création utilisateur non-root + clé SSH")
[[ "${SKIP_SSH}" == "false" ]] && PLAN_STEPS+=("2. Durcissement SSH (port custom + désactivation root + clé only)")
[[ "${SKIP_FAIL2BAN}" == "false" ]] && PLAN_STEPS+=("3. Installation fail2ban + whitelist IP admin")
[[ "${SKIP_UFW}" == "false" ]] && PLAN_STEPS+=("4. Configuration UFW (pare-feu)")
[[ "${SKIP_UPDATES}" == "false" ]] && PLAN_STEPS+=("5. Mises à jour système + auto-upgrades")

echo -e "${BOLD}Étapes prévues :${RESET}"
echo ""
for step in "${PLAN_STEPS[@]}"; do
    echo -e "  ${CYAN}▸${RESET} ${step}"
done

echo ""
log_warn "Vous serez sollicité à chaque étape critique pour validation"
log_warn "GARDEZ une session SSH de secours ouverte (filet de sécurité)"
echo ""

if ! ask_yes_no "Démarrer la sécurisation ?" "y"; then
    log_info "Sécurisation annulée"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════
# EXÉCUTION DES MODULES
# ═══════════════════════════════════════════════════════════════════

# Module 0 : Audit
if [[ "${SKIP_AUDIT}" == "false" ]]; then
    bash "${MODULES_DIR}/00-audit.sh"
    
    echo ""
    if ! ask_yes_no "Continuer la sécurisation ?" "y"; then
        log_info "Arrêt après audit"
        exit 0
    fi
fi

# Module 1 : User
if [[ "${SKIP_USER}" == "false" ]]; then
    bash "${MODULES_DIR}/01-create-user.sh"
    
    # Récupérer le user créé pour les modules suivants
    if [[ -z "${NEW_USER}" ]]; then
        NEW_USER="${NEW_USER:-mor}"
        export NEW_USER
    fi
fi

# Module 2 : SSH Hardening
if [[ "${SKIP_SSH}" == "false" ]]; then
    SSH_USER="${NEW_USER}" \
    bash "${MODULES_DIR}/02-ssh-harden.sh"
fi

# Module 3 : Fail2ban
if [[ "${SKIP_FAIL2BAN}" == "false" ]]; then
    bash "${MODULES_DIR}/03-fail2ban.sh"
fi

# Module 4 : UFW
if [[ "${SKIP_UFW}" == "false" ]]; then
    bash "${MODULES_DIR}/04-ufw.sh"
fi

# Module 5 : Updates
if [[ "${SKIP_UPDATES}" == "false" ]]; then
    bash "${MODULES_DIR}/05-updates.sh"
fi

# ═══════════════════════════════════════════════════════════════════
# RÉCAP FINAL
# ═══════════════════════════════════════════════════════════════════

log_section "🎉 SÉCURISATION TERMINÉE"

echo -e "${BOLD}Récapitulatif final :${RESET}"
echo ""

# Re-détecter pour le récap
detect_ssh_socket_activation
detect_ufw
detect_fail2ban

[[ "${SKIP_USER}" == "false" ]] && echo -e "  ${CHECK} Utilisateur non-root créé"
[[ "${SKIP_SSH}" == "false" ]] && echo -e "  ${CHECK} SSH durci (port ${SSH_NEW_PORT}, root no, password no)"
[[ "${FAIL2BAN_ACTIVE}" == "true" ]] && echo -e "  ${CHECK} Fail2ban actif"
[[ "${UFW_ACTIVE}" == "true" ]] && echo -e "  ${CHECK} UFW pare-feu actif"
[[ "${SKIP_UPDATES}" == "false" ]] && echo -e "  ${CHECK} Mises à jour automatiques activées"

echo ""
log_info "Log complet : ${LOG_FILE}"
echo ""
log_info "Prochaines étapes recommandées :"
echo -e "  ${DIM}1. Tester votre accès SSH depuis un autre terminal${RESET}"
echo -e "  ${DIM}2. Garder cette session ouverte 24h pour valider${RESET}"
echo -e "  ${DIM}3. Après 24h, fermer le port 22 si tout va bien${RESET}"
echo -e "  ${DIM}   sudo ufw delete allow 22/tcp${RESET}"
echo ""

log_success "Bonne route ! Votre VPS est maintenant sécurisé. 🛡️"
