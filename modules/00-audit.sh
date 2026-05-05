#!/usr/bin/env bash
# Module 00 : Audit initial du VPS
# Peut être lancé seul : sudo ./modules/00-audit.sh

set -euo pipefail

# Récupérer le chemin du script et de la lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"
LIB_DIR="${PROJECT_ROOT}/lib"

# Charger les libs
# shellcheck source=../lib/colors.sh
source "${LIB_DIR}/colors.sh"
# shellcheck source=../lib/logging.sh
source "${LIB_DIR}/logging.sh"
# shellcheck source=../lib/checks.sh
source "${LIB_DIR}/checks.sh"

# Initialisation
init_logging
require_root

# ═══════════════════════════════════════════════════════════════════
# AUDIT INITIAL
# ═══════════════════════════════════════════════════════════════════

log_section "AUDIT DE SÉCURITÉ DU VPS"

# 1. Système
log_step "1. INFORMATIONS SYSTÈME"

PUBLIC_IP="$(get_public_ip || echo "unknown")"
echo -e "  ${BOLD}Hostname${RESET}     : $(hostname)"
echo -e "  ${BOLD}IP publique${RESET}  : ${PUBLIC_IP}"
echo -e "  ${BOLD}Date${RESET}         : $(date)"
echo -e "  ${BOLD}Uptime${RESET}       : $(uptime -p)"

detect_ubuntu_version

UPDATES_COUNT="$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0)"
echo -e "  ${BOLD}MAJ en attente${RESET} : ${UPDATES_COUNT}"

if [[ -f /var/run/reboot-required ]]; then
    log_warn "Un redémarrage est nécessaire"
fi

# 2. Utilisateurs
log_step "2. UTILISATEURS"

echo -e "  ${BOLD}Utilisateurs avec shell${RESET} :"
grep -E "/bin/(bash|sh)$" /etc/passwd | cut -d: -f1 | sed 's/^/    ▸ /'

echo ""
echo -e "  ${BOLD}Utilisateurs sudo${RESET} :"
SUDO_USERS="$(getent group sudo | cut -d: -f4 | tr ',' '\n')"
if [[ -z "${SUDO_USERS}" ]]; then
    echo "    ${RED}(aucun)${RESET}"
else
    echo "${SUDO_USERS}" | sed 's/^/    ▸ /'
fi

# Comptage des UID 0 (détection backdoor)
UID0_COUNT="$(awk -F: '$3 == 0 {print $1}' /etc/passwd | wc -l)"
if [[ "${UID0_COUNT}" -gt 1 ]]; then
    log_warn "Plus d'un utilisateur avec UID 0 détecté !"
    awk -F: '$3 == 0 {print "    ▸ "$1}' /etc/passwd
fi

# 3. SSH
log_step "3. CONFIGURATION SSH"

detect_ssh_socket_activation

echo ""
echo -e "  ${BOLD}Configuration sshd_config principal${RESET} :"
grep -E "^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|AllowUsers|MaxAuthTries)" /etc/ssh/sshd_config 2>/dev/null | sed 's/^/    ▸ /' || echo "    (paramètres par défaut)"

echo ""
echo -e "  ${BOLD}Fichiers override (sshd_config.d)${RESET} :"
if [[ -d /etc/ssh/sshd_config.d ]] && [[ -n "$(ls -A /etc/ssh/sshd_config.d 2>/dev/null)" ]]; then
    # `ls -la` est volontaire ici : on veut le format humain (perms + dates).
    # shellcheck disable=SC2012
    ls -la /etc/ssh/sshd_config.d/ | tail -n +2 | sed 's/^/    /'
else
    echo "    (aucun)"
fi

echo ""
echo -e "  ${BOLD}Ports SSH en écoute${RESET} :"
ss -tlnp 2>/dev/null | grep ssh | awk '{print "    ▸ " $4}' || echo "    (aucun port SSH détecté)"

# 4. Ports en écoute
log_step "4. PORTS EN ÉCOUTE"

echo -e "  ${BOLD}Tous les ports TCP en écoute${RESET} :"
ss -tlnp 2>/dev/null | tail -n +2 | awk '{print "    ▸ " $4 "  →  " $7}' | sort -u

# 5. Pare-feu UFW
log_step "5. PARE-FEU UFW"
detect_ufw

if [[ "${UFW_INSTALLED}" == "true" ]] && [[ "${UFW_ACTIVE}" == "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Règles UFW actives${RESET} :"
    ufw status verbose 2>/dev/null | head -20 | sed 's/^/    /'
fi

# 6. Fail2ban
log_step "6. FAIL2BAN"
detect_fail2ban

if [[ "${FAIL2BAN_ACTIVE}" == "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Status Fail2ban${RESET} :"
    fail2ban-client status 2>/dev/null | sed 's/^/    /'
    
    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo ""
        echo -e "  ${BOLD}Jail SSHD${RESET} :"
        fail2ban-client status sshd 2>/dev/null | sed 's/^/    /'
    fi
fi

# 7. Tailscale
log_step "7. TAILSCALE"
detect_tailscale

if [[ "${TAILSCALE_INSTALLED}" == "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Status Tailscale${RESET} :"
    tailscale status 2>/dev/null | head -10 | sed 's/^/    /'
fi

# 8. Docker
log_step "8. DOCKER"
detect_docker

if [[ "${DOCKER_INSTALLED}" == "true" ]]; then
    echo ""
    echo -e "  ${BOLD}Containers actifs${RESET} :"
    docker ps --format "    ▸ {{.Names}} ({{.Status}})" 2>/dev/null | head -15 || echo "    (aucun container)"
    
    if [[ "${DOCKER_SWARM}" == "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Services Docker Swarm${RESET} :"
        docker service ls 2>/dev/null | sed 's/^/    /'
    fi
fi

# 9. MAJ automatiques
log_step "9. MISES À JOUR AUTOMATIQUES"

if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
    log_success "Service unattended-upgrades actif"
else
    log_warn "Service unattended-upgrades inactif ou non installé"
fi

# 10. Ressources
log_step "10. RESSOURCES SYSTÈME"

echo -e "  ${BOLD}Mémoire${RESET} :"
free -h | head -2 | sed 's/^/    /'

echo ""
echo -e "  ${BOLD}Disque${RESET} :"
df -h / | tail -1 | awk '{print "    ▸ "$1": "$3" utilisés / "$2" total ("$5")"}'

# 11. Connexions récentes
log_step "11. DERNIÈRES CONNEXIONS SSH"

last -n 5 -F 2>/dev/null | head -5 | sed 's/^/  ▸ /' || echo "  (aucune donnée)"

# 12. Recommandations
log_section "ANALYSE & RECOMMANDATIONS"

ISSUES=0
RECOMMENDATIONS=()

# Check 1 : Root login
if grep -q "^PermitRootLogin yes" /etc/ssh/sshd_config 2>/dev/null; then
    RECOMMENDATIONS+=("${CROSS} Désactiver le login root SSH (PermitRootLogin no)")
    ((++ISSUES))
fi

# Check 2 : Password auth
if ! grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    if ! grep -rq "^PasswordAuthentication no" /etc/ssh/sshd_config.d/ 2>/dev/null; then
        RECOMMENDATIONS+=("${CROSS} Désactiver l'authentification par mot de passe SSH")
        ((++ISSUES))
    fi
fi

# Check 3 : SSH port
if ss -tlnp 2>/dev/null | grep -qE ":22\s" && ! ss -tlnp 2>/dev/null | grep -qE ":2222\s"; then
    RECOMMENDATIONS+=("${WARN}  SSH uniquement sur port 22 (envisager port secondaire)")
fi

# Check 4 : UFW
if [[ "${UFW_INSTALLED}" != "true" ]]; then
    RECOMMENDATIONS+=("${CROSS} Installer et activer UFW")
    ((++ISSUES))
elif [[ "${UFW_ACTIVE}" != "true" ]]; then
    RECOMMENDATIONS+=("${CROSS} UFW installé mais inactif - l'activer")
    ((++ISSUES))
fi

# Check 5 : Fail2ban
if [[ "${FAIL2BAN_INSTALLED}" != "true" ]]; then
    RECOMMENDATIONS+=("${CROSS} Installer fail2ban")
    ((++ISSUES))
elif [[ "${FAIL2BAN_ACTIVE}" != "true" ]]; then
    RECOMMENDATIONS+=("${CROSS} Fail2ban installé mais inactif")
    ((++ISSUES))
fi

# Check 6 : Updates
if [[ "${UPDATES_COUNT}" -gt 10 ]]; then
    RECOMMENDATIONS+=("${WARN}  ${UPDATES_COUNT} mises à jour en attente - planifier une MAJ")
fi

# Check 7 : Sudo users
if [[ -z "${SUDO_USERS// }" ]]; then
    RECOMMENDATIONS+=("${CROSS} Aucun utilisateur sudo - créer un user non-root")
    ((++ISSUES))
fi

# Check 8 : Reboot required
if [[ -f /var/run/reboot-required ]]; then
    RECOMMENDATIONS+=("${WARN}  Redémarrage en attente (kernel ou autre)")
fi

# Affichage des recommandations
if [[ ${#RECOMMENDATIONS[@]} -eq 0 ]]; then
    log_success "Aucune recommandation critique - bonne config !"
else
    echo -e "${BOLD}Recommandations :${RESET}"
    echo ""
    for rec in "${RECOMMENDATIONS[@]}"; do
        echo -e "  ${rec}"
    done
fi

# Score de sécurité simple
echo ""
if [[ ${ISSUES} -eq 0 ]]; then
    SCORE="${GREEN}${BOLD}Excellent${RESET}"
elif [[ ${ISSUES} -le 2 ]]; then
    SCORE="${YELLOW}${BOLD}Moyen${RESET}"
else
    SCORE="${RED}${BOLD}Faible${RESET}"
fi
echo -e "${BOLD}Score de sécurité : ${SCORE}${DIM} (${ISSUES} problèmes critiques)${RESET}"

# Fin
echo ""
log_section "FIN DE L'AUDIT"
log_info "Log complet : ${LOG_FILE}"
echo ""
