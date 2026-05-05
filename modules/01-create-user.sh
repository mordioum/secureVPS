#!/usr/bin/env bash
# Module 01 : Création utilisateur non-root avec sudo et clé SSH
# Peut être lancé seul : sudo ./modules/01-create-user.sh

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

# Initialisation
init_logging
require_root

# ═══════════════════════════════════════════════════════════════════
# CRÉATION USER + CLÉ SSH
# ═══════════════════════════════════════════════════════════════════

log_section "CRÉATION D'UN UTILISATEUR NON-ROOT"

# Variables (peuvent venir de l'environnement ou args)
NEW_USER="${NEW_USER:-}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

# Si pas de user fourni, demander
if [[ -z "${NEW_USER}" ]]; then
    NEW_USER="$(ask_input "Nom du nouvel utilisateur" "mor" is_valid_username)"
fi

# Vérifier si l'user existe déjà
if user_exists "${NEW_USER}"; then
    log_warn "L'utilisateur '${NEW_USER}' existe déjà"
    
    if user_has_sudo "${NEW_USER}"; then
        log_success "Il a déjà les droits sudo"
    else
        if ask_yes_no "Lui ajouter les droits sudo ?" "y"; then
            usermod -aG sudo "${NEW_USER}"
            log_success "Droits sudo ajoutés à ${NEW_USER}"
        fi
    fi
else
    # Création de l'utilisateur
    log_step "Création de l'utilisateur ${NEW_USER}"
    
    log_info "Vous allez devoir saisir un mot de passe FORT pour ${NEW_USER}"
    log_info "Conseil : utilisez 16+ caractères avec majuscules, chiffres, symboles"
    log_info "Ce mot de passe servira pour 'sudo', donc gardez-le précieusement"
    echo ""
    
    if ! adduser --gecos "" "${NEW_USER}"; then
        log_error "Échec de la création de l'utilisateur"
        exit 1
    fi
    
    log_success "Utilisateur ${NEW_USER} créé"
    
    # Ajout sudo
    log_step "Ajout des droits sudo"
    usermod -aG sudo "${NEW_USER}"
    log_success "Droits sudo ajoutés"
fi

# Préparation du dossier .ssh
log_step "Préparation du dossier ~/.ssh"

USER_HOME="$(getent passwd "${NEW_USER}" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
touch "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
chown -R "${NEW_USER}:${NEW_USER}" "${SSH_DIR}"

log_success "Dossier .ssh préparé pour ${NEW_USER}"

# Ajout de la clé SSH
log_step "Ajout d'une clé SSH publique"

if [[ -z "${SSH_PUBKEY}" ]]; then
    echo ""
    log_info "Vous devez fournir votre clé SSH publique"
    log_info "Sur votre Mac/Linux, récupérez-la avec :"
    echo "    ${DIM}cat ~/.ssh/id_ed25519.pub${RESET}"
    echo "    ${DIM}# ou${RESET}"
    echo "    ${DIM}cat ~/.ssh/id_rsa.pub${RESET}"
    echo ""
    log_info "Sur Windows, dans PowerShell : Get-Content ~/.ssh/id_ed25519.pub"
    echo ""
    
    # Choix de la méthode
    # ask_choice retourne 1/2/3 via $?, ce qui ferait exit sous set -e :
    # le `|| choice=$?` neutralise set -e et capture le code retour.
    choice=0
    ask_choice "Méthode d'ajout de la clé SSH :" \
        "Coller la clé manuellement maintenant" \
        "L'ajouter plus tard avec ssh-copy-id depuis mon Mac/Linux" \
        "Sauter cette étape (DANGEREUX si on durcit ensuite SSH)" \
        || choice=$?

    case ${choice} in
        1)
            echo ""
            log_info "Collez votre clé publique entière (commence par 'ssh-' et finit par votre email/commentaire)"
            echo -e "${DIM}Appuyez sur Entrée à la fin :${RESET}"
            read -r SSH_PUBKEY

            # Validation basique
            if [[ ! "${SSH_PUBKEY}" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-) ]]; then
                log_error "La clé ne semble pas valide (doit commencer par ssh-rsa, ssh-ed25519 ou ecdsa-sha2-)"
                exit 1
            fi
            ;;
        2)
            log_info "Pour ajouter votre clé plus tard depuis votre machine :"
            echo "    ${DIM}ssh-copy-id ${NEW_USER}@$(hostname -I | awk '{print $1}')${RESET}"
            echo ""
            log_warn "ATTENTION : ne durcissez pas SSH avant d'avoir ajouté la clé !"
            exit 0
            ;;
        3)
            log_warn "Étape sautée - n'oubliez pas d'ajouter la clé avant de durcir SSH"
            exit 0
            ;;
    esac
fi

# Vérifier si la clé n'est pas déjà présente
if grep -qF "${SSH_PUBKEY}" "${AUTH_KEYS}" 2>/dev/null; then
    log_warn "Cette clé est déjà autorisée pour ${NEW_USER}"
else
    echo "${SSH_PUBKEY}" >> "${AUTH_KEYS}"
    log_success "Clé SSH ajoutée à authorized_keys"
fi

# Statistiques
KEY_COUNT="$(grep -c "^ssh-" "${AUTH_KEYS}" 2>/dev/null || echo 0)"
log_info "Total de clés SSH autorisées pour ${NEW_USER} : ${KEY_COUNT}"

# Récap
log_section "USER CRÉÉ AVEC SUCCÈS"

echo -e "  ${BOLD}Utilisateur${RESET}  : ${NEW_USER}"
echo -e "  ${BOLD}Home${RESET}         : ${USER_HOME}"
echo -e "  ${BOLD}Sudo${RESET}         : $(user_has_sudo "${NEW_USER}" && echo "✅ oui" || echo "❌ non")"
echo -e "  ${BOLD}Clés SSH${RESET}     : ${KEY_COUNT}"

echo ""
log_info "Test la connexion depuis votre Mac/Linux AVANT de durcir SSH :"
echo "    ${DIM}ssh ${NEW_USER}@$(hostname -I | awk '{print $1}')${RESET}"
echo ""

press_any_key "Une fois le test SSH validé, appuyez sur Entrée pour continuer..."

# Export pour la suite
export NEW_USER
