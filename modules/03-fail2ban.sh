#!/usr/bin/env bash
# Module 03 : Installation et configuration de fail2ban
# Avec whitelist de l'IP de l'admin DÈS LE DÉBUT (leçon SAFRU)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# FAIL2BAN
# ═══════════════════════════════════════════════════════════════════

log_section "INSTALLATION & CONFIGURATION DE FAIL2BAN"

# Variables
ADMIN_IP="${ADMIN_IP:-}"
SSH_NEW_PORT="${SSH_NEW_PORT:-2222}"
F2B_BANTIME="${F2B_BANTIME:-86400}"          # 24h
F2B_FINDTIME="${F2B_FINDTIME:-600}"          # 10 min
F2B_MAXRETRY="${F2B_MAXRETRY:-3}"

# Demander l'IP de l'admin (CRITIQUE pour ne pas se bannir)
log_step "Whitelist de votre IP (CRITIQUE)"

echo ""
log_warn "Si vous ne whitelistez pas votre IP, vous risquez d'être banni"
log_warn "C'est arrivé sur de vrais cas de production !"
echo ""

if [[ -z "${ADMIN_IP}" ]]; then
    log_info "Pour récupérer votre IP publique, sur votre Mac/Linux :"
    echo "    ${DIM}curl -4 ifconfig.me${RESET}"
    echo ""

    ADMIN_IP="$(ask_input "Votre IP publique à whitelister" "" is_valid_ipv4)"
else
    # Valider même si ADMIN_IP arrive depuis l'environnement / CLI :
    # une valeur malformée corromprait jail.local et fail2ban refuserait de démarrer.
    if ! is_valid_ipv4 "${ADMIN_IP}"; then
        log_error "ADMIN_IP fourni est invalide : '${ADMIN_IP}'"
        log_info "Format attendu : IPv4 (ex. 196.207.227.109)"
        exit 1
    fi
fi

log_success "IP whitelistée : ${ADMIN_IP}"

# Demander le port SSH
log_step "Configuration des ports SSH à surveiller"

if [[ -z "${SSH_NEW_PORT_FORCED:-}" ]]; then
    SSH_NEW_PORT="$(ask_input "Port SSH secondaire" "2222" is_valid_port)"
fi

# Récap
echo ""
show_summary_and_confirm "Configuration Fail2ban" \
    "Bantime=${F2B_BANTIME}s ($(( F2B_BANTIME / 3600 ))h)" \
    "Findtime=${F2B_FINDTIME}s ($(( F2B_FINDTIME / 60 )) min)" \
    "Maxretry=${F2B_MAXRETRY} tentatives" \
    "Ports SSH=22, ${SSH_NEW_PORT}" \
    "IP whitelistée=${ADMIN_IP}" \
    "Mode=aggressive" \
    || { log_warn "Configuration annulée"; exit 0; }

# Installation
log_step "Installation de fail2ban"

apt update -qq
apt install -y fail2ban

log_success "Fail2ban installé"

# Configuration
log_step "Configuration de jail.local"

JAIL_LOCAL="/etc/fail2ban/jail.local"

# Backup si existe déjà
if [[ -f "${JAIL_LOCAL}" ]]; then
    cp "${JAIL_LOCAL}" "${JAIL_LOCAL}.bak.$(date +%Y%m%d-%H%M%S)"
    log_info "Backup de l'ancienne config créé"
fi

cat > "${JAIL_LOCAL}" << EOF
# Configuration fail2ban (vps-secure)
# Généré le $(date)

[DEFAULT]
# Durée du ban (en secondes)
bantime = ${F2B_BANTIME}

# Fenêtre de détection (en secondes)
findtime = ${F2B_FINDTIME}

# Nombre de tentatives avant ban
maxretry = ${F2B_MAXRETRY}

# IPs jamais bannies (whitelist)
ignoreip = 127.0.0.1/8 ::1 ${ADMIN_IP}

# Mode incrémental : ban plus long en cas de récidive
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 604800

[sshd]
enabled = true
port = 22,${SSH_NEW_PORT}
backend = systemd
mode = aggressive
maxretry = ${F2B_MAXRETRY}
EOF

log_success "Fichier ${JAIL_LOCAL} créé"

# Activation et démarrage
log_step "Activation et démarrage du service"

systemctl enable fail2ban
systemctl restart fail2ban

# Attendre que le service démarre
sleep 3

# Vérifier que c'est actif
if systemctl is-active --quiet fail2ban; then
    log_success "Fail2ban actif"
else
    log_error "Fail2ban n'a pas démarré correctement"
    journalctl -u fail2ban --no-pager -n 20
    exit 1
fi

# Vérification de la whitelist
log_step "Vérification de la whitelist"

sleep 2
if fail2ban-client get sshd ignoreip 2>/dev/null | grep -q "${ADMIN_IP}"; then
    log_success "IP ${ADMIN_IP} bien whitelistée"
else
    log_warn "Impossible de vérifier la whitelist (réessayez dans 5s)"
fi

# Status
log_step "Status fail2ban"

echo ""
fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || true

# Récap
log_section "FAIL2BAN CONFIGURÉ"

echo -e "${BOLD}Récapitulatif :${RESET}"
echo -e "  ${CHECK} Service fail2ban actif"
echo -e "  ${CHECK} Surveillance des ports 22 et ${SSH_NEW_PORT}"
echo -e "  ${CHECK} Mode aggressive"
echo -e "  ${CHECK} IP ${ADMIN_IP} whitelistée"
echo -e "  ${CHECK} Bans incrémentaux (récidive = ban plus long)"
echo ""

log_info "Commandes utiles :"
echo -e "  ${DIM}sudo fail2ban-client status${RESET}              # Liste des jails"
echo -e "  ${DIM}sudo fail2ban-client status sshd${RESET}         # Détail SSH"
echo -e "  ${DIM}sudo fail2ban-client unban <IP>${RESET}          # Débannir une IP"
echo -e "  ${DIM}sudo fail2ban-client get sshd ignoreip${RESET}   # Voir la whitelist"
echo ""

log_info "Pour ajouter une IP à la whitelist :"
echo -e "  ${DIM}sudo nano /etc/fail2ban/jail.local${RESET}"
echo -e "  ${DIM}# Modifier la ligne 'ignoreip = ...'${RESET}"
echo -e "  ${DIM}sudo systemctl reload fail2ban${RESET}"
