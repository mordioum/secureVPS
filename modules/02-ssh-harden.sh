#!/usr/bin/env bash
# Module 02 : Durcissement SSH (port custom + désactivation root + clé seulement)
# Compatible Ubuntu 22.04, 24.04, 26.04 (gère socket activation)
# Peut être lancé seul : sudo ./modules/02-ssh-harden.sh

set -euo pipefail

# Charger les libs
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
# DURCISSEMENT SSH
# ═══════════════════════════════════════════════════════════════════

log_section "DURCISSEMENT SSH"

# Variables
SSH_USER="${NEW_USER:-${SSH_USER:-mor}}"
SSH_NEW_PORT="${SSH_NEW_PORT:-2222}"
KEEP_PORT_22="${KEEP_PORT_22:-true}"
# SSH_ALLOW_USERS : liste séparée par espaces des utilisateurs autorisés.
# Si non fournie, on retombe sur SSH_USER (un seul admin).
# Exemple : SSH_ALLOW_USERS="mor alice bob" ./02-ssh-harden.sh
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-${SSH_USER}}"

detect_ubuntu_version
detect_ssh_socket_activation

# Vérifier que l'user existe et a les droits
log_step "Vérifications préalables"

if ! user_exists "${SSH_USER}"; then
    log_error "L'utilisateur '${SSH_USER}' n'existe pas"
    log_info "Lancez d'abord : sudo ./modules/01-create-user.sh"
    exit 1
fi

# Vérifier qu'il a au moins une clé SSH
USER_HOME="$(getent passwd "${SSH_USER}" | cut -d: -f6)"
AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"

KEY_COUNT=0
if [[ -f "${AUTH_KEYS}" ]]; then
    KEY_COUNT="$(grep -c "^ssh-" "${AUTH_KEYS}" 2>/dev/null || echo 0)"
fi

if [[ "${KEY_COUNT}" -eq 0 ]]; then
    log_error "L'utilisateur '${SSH_USER}' n'a AUCUNE clé SSH autorisée"
    log_error "Ajouter une clé d'abord, sinon vous serez verrouillé hors du serveur !"
    log_info "Module à utiliser : sudo ./modules/01-create-user.sh"
    exit 1
fi

log_success "User ${SSH_USER} : ${KEY_COUNT} clé(s) SSH OK"

# Demander le port custom
if [[ -z "${SSH_NEW_PORT_FORCED:-}" ]]; then
    SSH_NEW_PORT="$(ask_input "Port SSH secondaire (filet de sécurité)" "2222" is_valid_port)"
fi

# Récap avant action
echo ""
show_summary_and_confirm "Configuration SSH à appliquer" \
    "Utilisateurs autorisés=${SSH_ALLOW_USERS}" \
    "Port standard=22 (gardé pour transition)" \
    "Port secondaire=${SSH_NEW_PORT}" \
    "Login root=DÉSACTIVÉ" \
    "Auth password=DÉSACTIVÉE" \
    "Auth par clé=ACTIVÉE" \
    "Max tentatives=3" \
    || { log_warn "Configuration annulée"; exit 0; }

# Backup config
log_step "Backup de la configuration SSH actuelle"

BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BACKUP_DIR}"
cp -r /etc/ssh/sshd_config "${BACKUP_DIR}/"
cp -r /etc/ssh/sshd_config.d "${BACKUP_DIR}/" 2>/dev/null || true

log_success "Backup dans ${BACKUP_DIR}"

# Création du fichier de port (avec garder 22 ou pas)
log_step "Configuration des ports SSH"

PORT_CONF="/etc/ssh/sshd_config.d/99-custom-port.conf"

cat > "${PORT_CONF}" << EOF
# Configuration des ports SSH (vps-secure)
# Généré le $(date)
Port 22
Port ${SSH_NEW_PORT}
EOF

log_success "Fichier ${PORT_CONF} créé"

# Pour Ubuntu 24.04+ avec socket activation
if [[ "${SSH_SOCKET_ACTIVATION}" == "true" ]]; then
    log_step "Configuration du socket SSH (Ubuntu 24+/26+)"
    
    SOCKET_OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
    SOCKET_OVERRIDE="${SOCKET_OVERRIDE_DIR}/override.conf"
    
    mkdir -p "${SOCKET_OVERRIDE_DIR}"
    cat > "${SOCKET_OVERRIDE}" << EOF
# Override pour ssh.socket - vps-secure
[Socket]
ListenStream=
ListenStream=22
ListenStream=${SSH_NEW_PORT}
EOF
    
    log_success "Override ${SOCKET_OVERRIDE} créé"
    
    systemctl daemon-reload
    log_success "Systemd rechargé"
fi

# Vérifier les fichiers cloud-init qui peuvent override
log_step "Vérification des fichiers cloud-init"

CLOUD_INIT_FILE="/etc/ssh/sshd_config.d/50-cloud-init.conf"
if [[ -f "${CLOUD_INIT_FILE}" ]]; then
    log_warn "Fichier cloud-init détecté : ${CLOUD_INIT_FILE}"
    log_warn "Ce fichier peut forcer PasswordAuthentication=yes"
    
    if ask_yes_no "Désactiver ce fichier (recommandé) ?" "y"; then
        mv "${CLOUD_INIT_FILE}" "${CLOUD_INIT_FILE}.disabled"
        log_success "Fichier renommé en ${CLOUD_INIT_FILE}.disabled"
    fi
fi

# Création du fichier de durcissement
log_step "Création du fichier de durcissement"

HARDEN_CONF="/etc/ssh/sshd_config.d/99-hardening.conf"

cat > "${HARDEN_CONF}" << EOF
# Configuration de durcissement SSH (vps-secure)
# Généré le $(date)

# Désactivation du login root
PermitRootLogin no

# Authentification par clé uniquement
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no

# Limiter les utilisateurs autorisés (liste séparée par espaces)
AllowUsers ${SSH_ALLOW_USERS}

# Sécurité supplémentaire
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
PermitUserEnvironment no

# Logs
LogLevel VERBOSE
EOF

log_success "Fichier ${HARDEN_CONF} créé"

# Validation syntax
log_step "Validation de la configuration"

if ! sshd -t 2>&1 | tee -a "${LOG_FILE}"; then
    log_error "ERREUR de syntaxe dans la config SSH !"
    log_error "Configuration NON appliquée"
    log_info "Restaurer avec : cp -r ${BACKUP_DIR}/* /etc/ssh/"
    exit 1
fi

log_success "Syntaxe SSH valide"

# Vérification config effective
log_step "Vérification de la configuration effective"

echo ""
echo -e "${BOLD}Paramètres effectifs (avant reload) :${RESET}"
sshd -T 2>/dev/null | grep -E "^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|allowusers|maxauthtries)" | sed 's/^/  /'

# Vérification critique
EFFECTIVE_PASSWORD_AUTH="$(sshd -T 2>/dev/null | grep "^passwordauthentication" | awk '{print $2}')"
if [[ "${EFFECTIVE_PASSWORD_AUTH}" != "no" ]]; then
    log_error "PasswordAuthentication est encore '${EFFECTIVE_PASSWORD_AUTH}' (devrait être 'no')"
    log_error "Un autre fichier override doit être en cause"
    log_info "Vérifiez : ls -la /etc/ssh/sshd_config.d/"
    
    if ! ask_yes_no "Continuer quand même (DANGEREUX) ?" "n"; then
        exit 1
    fi
fi

# Reload SSH
log_step "Rechargement du service SSH"

echo ""
log_warn "ATTENTION : si vous êtes connecté en SSH, NE FERMEZ PAS cette session"
log_warn "Ouvrez un AUTRE terminal et testez d'abord la connexion par clé"
echo ""

if ! ask_yes_no "Recharger SSH maintenant ?" "y"; then
    log_warn "SSH NON rechargé - les changements ne sont pas actifs"
    log_info "Pour activer plus tard : sudo systemctl reload ssh"
    exit 0
fi

if [[ "${SSH_SOCKET_ACTIVATION}" == "true" ]]; then
    systemctl restart ssh.socket
    # ssh.service n'est pas toujours présent en mode socket-activation.
    # On loggue l'éventuelle erreur (au lieu de la swallow silencieusement)
    # et on continue : le socket suffit dans ce mode.
    if ! systemctl restart ssh 2>/tmp/ssh-restart-err; then
        if [[ -s /tmp/ssh-restart-err ]]; then
            log_warn "ssh.service non redémarré (socket-activation actif) :"
            sed 's/^/    /' /tmp/ssh-restart-err
        fi
        rm -f /tmp/ssh-restart-err
    fi
else
    systemctl reload ssh
fi

log_success "SSH rechargé"

# Vérifier que les ports écoutent
sleep 1
log_step "Vérification des ports en écoute"

LISTENING_PORTS="$(ss -tlnp 2>/dev/null | grep ssh | awk '{print $4}')"
echo "${LISTENING_PORTS}" | sed 's/^/  ▸ /'

if echo "${LISTENING_PORTS}" | grep -q ":${SSH_NEW_PORT}"; then
    log_success "Port ${SSH_NEW_PORT} en écoute"
else
    log_error "Port ${SSH_NEW_PORT} N'est PAS en écoute"
fi

# Tests à effectuer côté client
log_section "TESTS À EFFECTUER DEPUIS VOTRE MACHINE LOCALE"

local_ip="$(hostname -I | awk '{print $1}')"

echo -e "${BOLD}Sur votre Mac/Linux/Windows, ouvrez un NOUVEAU terminal et testez :${RESET}"
echo ""
echo -e "  ${GREEN}${CHECK} TEST 1${RESET} - Nouveau port (DOIT marcher) :"
echo -e "    ${DIM}ssh -p ${SSH_NEW_PORT} ${SSH_USER}@${local_ip}${RESET}"
echo ""
echo -e "  ${GREEN}${CHECK} TEST 2${RESET} - Port 22 (DOIT marcher, filet) :"
echo -e "    ${DIM}ssh -p 22 ${SSH_USER}@${local_ip}${RESET}"
echo ""
echo -e "  ${RED}${CROSS} TEST 3${RESET} - Root (DOIT être refusé) :"
echo -e "    ${DIM}ssh -p ${SSH_NEW_PORT} root@${local_ip}${RESET}"
echo -e "    ${DIM}# Attendu : Permission denied (publickey)${RESET}"
echo ""
echo -e "  ${RED}${CROSS} TEST 4${RESET} - Password (DOIT être refusé) :"
echo -e "    ${DIM}ssh -p ${SSH_NEW_PORT} -o PubkeyAuthentication=no -o PreferredAuthentications=password ${SSH_USER}@${local_ip}${RESET}"
echo -e "    ${DIM}# Attendu : Permission denied (publickey)${RESET}"
echo ""

log_info "GARDEZ votre session actuelle ouverte pendant les tests !"
log_info "En cas de problème, restaurez avec :"
echo -e "    ${DIM}sudo cp -r ${BACKUP_DIR}/* /etc/ssh/${RESET}"
echo -e "    ${DIM}sudo systemctl reload ssh${RESET}"
echo ""

press_any_key "Une fois les 4 tests validés, appuyez sur Entrée pour terminer..."

log_section "DURCISSEMENT SSH TERMINÉ"

echo -e "${BOLD}Récapitulatif :${RESET}"
echo -e "  ${CHECK} Port secondaire ${SSH_NEW_PORT} actif"
echo -e "  ${CHECK} Port 22 maintenu (filet de sécurité)"
echo -e "  ${CHECK} Login root désactivé"
echo -e "  ${CHECK} Authentification par mot de passe désactivée"
echo -e "  ${CHECK} AllowUsers ${SSH_ALLOW_USERS}"
echo -e "  ${CHECK} Backup : ${BACKUP_DIR}"
echo ""

log_info "Prochaines étapes : installer fail2ban + UFW"
log_info "Modules : ./modules/03-fail2ban.sh puis ./modules/04-ufw.sh"
