#!/usr/bin/env bash
# Module 04 : Configuration UFW (pare-feu)
# Détecte automatiquement Docker pour ne pas casser les services

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
# UFW
# ═══════════════════════════════════════════════════════════════════

log_section "CONFIGURATION DU PARE-FEU UFW"

# Variables
SSH_NEW_PORT="${SSH_NEW_PORT:-2222}"
ALLOW_WEB="${ALLOW_WEB:-true}"
UFW_MODE="${UFW_MODE:-}"  # 'strict' ou 'modere' ou ''

detect_docker
detect_tailscale

# Demander le port SSH
if [[ -z "${SSH_NEW_PORT_FORCED:-}" ]]; then
    SSH_NEW_PORT="$(ask_input "Port SSH secondaire à autoriser" "2222" is_valid_port)"
fi

# Choisir le mode
if [[ -z "${UFW_MODE}" ]]; then
    log_step "Mode de configuration UFW"
    
    echo ""
    echo -e "${BOLD}3 modes disponibles :${RESET}"
    echo ""
    echo -e "  ${BOLD}1) Strict${RESET}     : SSH seulement"
    echo -e "     ${DIM}Pour serveur sans services publics ou avec Tailscale${RESET}"
    echo ""
    echo -e "  ${BOLD}2) Web${RESET}        : SSH + 80 + 443"
    echo -e "     ${DIM}Pour serveur web standard${RESET}"
    echo ""
    echo -e "  ${BOLD}3) Production${RESET} : SSH + 80 + 443 + détection Docker"
    echo -e "     ${DIM}Pour serveur avec apps Docker (Dokploy, NPM, etc.)${RESET}"
    echo ""
    
    # ask_choice retourne 1/2/3 via $? — neutraliser set -e
    ufw_mode_choice=0
    ask_choice "Quel mode ?" "Strict" "Web" "Production (Docker auto-detect)" || ufw_mode_choice=$?
    case ${ufw_mode_choice} in
        1) UFW_MODE="strict" ;;
        2) UFW_MODE="web" ;;
        3) UFW_MODE="production" ;;
    esac
fi

log_info "Mode choisi : ${UFW_MODE}"

# Avertissement critique : Docker écrit ses propres règles iptables qui
# bypassent les règles UFW pour les ports publiés (-p host:container).
# Les règles UFW ci-dessous n'auront PAS d'effet sur les ports Docker exposés.
if [[ "${DOCKER_INSTALLED}" == "true" ]]; then
    echo ""
    log_warn "Docker détecté — IMPORTANT à savoir :"
    log_warn "  • Docker manipule iptables directement et BYPASSE les règles UFW"
    log_warn "    pour les ports publiés via 'docker run -p HOST:CONTAINER'."
    log_warn "  • Conséquence : 'default deny incoming' de UFW NE BLOQUE PAS"
    log_warn "    les ports Docker exposés. Vos containers restent atteignables."
    log_warn "  • Solutions possibles :"
    log_warn "    - ufw-docker (https://github.com/chaifeng/ufw-docker)"
    log_warn "    - publier sur 127.0.0.1: uniquement (-p 127.0.0.1:8080:80)"
    log_warn "    - utiliser la chaîne DOCKER-USER d'iptables"
    echo ""
fi

# Détection Docker pour mode production
DOCKER_PORTS=()
if [[ "${UFW_MODE}" == "production" ]] && [[ "${DOCKER_INSTALLED}" == "true" ]]; then
    log_step "Détection des ports Docker"
    
    # Récupérer les ports exposés par les containers
    while IFS= read -r port; do
        [[ -n "${port}" ]] && DOCKER_PORTS+=("${port}")
    done < <(ss -tlnp 2>/dev/null | grep "docker-proxy" | awk '{print $4}' | grep -oE '[0-9]+$' | sort -u)
    
    # Ajouter ports Swarm si présent
    if [[ "${DOCKER_SWARM}" == "true" ]]; then
        log_info "Docker Swarm détecté - ports 2377, 7946, 4789 ajoutés"
        DOCKER_PORTS+=("2377" "7946" "4789")
    fi
    
    if [[ ${#DOCKER_PORTS[@]} -gt 0 ]]; then
        log_success "Ports Docker détectés : ${DOCKER_PORTS[*]}"
    else
        log_info "Aucun port Docker exposé détecté"
    fi
fi

# Liste des ports à autoriser
ALLOWED_PORTS=()

# SSH toujours autorisé (mais limité si Tailscale)
if [[ "${TAILSCALE_INSTALLED}" == "true" ]]; then
    log_info "Tailscale détecté : SSH limité à 100.64.0.0/10"
    ALLOWED_PORTS+=("22:tcp:100.64.0.0/10:SSH (Tailscale only)")
    ALLOWED_PORTS+=("${SSH_NEW_PORT}:tcp:100.64.0.0/10:SSH new (Tailscale only)")
else
    ALLOWED_PORTS+=("22:tcp:any:SSH old (filet de sécurité)")
    ALLOWED_PORTS+=("${SSH_NEW_PORT}:tcp:any:SSH new")
fi

# Web si demandé
if [[ "${UFW_MODE}" == "web" ]] || [[ "${UFW_MODE}" == "production" ]]; then
    ALLOWED_PORTS+=("80:tcp:any:HTTP")
    ALLOWED_PORTS+=("443:tcp:any:HTTPS")
fi

# Ports Docker auto
if [[ "${UFW_MODE}" == "production" ]] && [[ ${#DOCKER_PORTS[@]} -gt 0 ]]; then
    for port in "${DOCKER_PORTS[@]}"; do
        # Ne pas re-ajouter 22, 80, 443
        if [[ "${port}" != "22" ]] && [[ "${port}" != "80" ]] && [[ "${port}" != "443" ]]; then
            ALLOWED_PORTS+=("${port}:tcp:any:Docker port ${port}")
        fi
    done
fi

# Récap des règles
log_step "Règles UFW à appliquer"

echo ""
echo -e "${BOLD}Politiques :${RESET}"
echo -e "  - Default incoming : ${RED}DENY${RESET}"
echo -e "  - Default outgoing : ${GREEN}ALLOW${RESET}"
echo ""
echo -e "${BOLD}Règles autorisées :${RESET}"
for rule in "${ALLOWED_PORTS[@]}"; do
    IFS=':' read -r p proto from comment <<< "${rule}"
    if [[ "${from}" == "any" ]]; then
        echo -e "  ${GREEN}✓${RESET} Port ${BOLD}${p}/${proto}${RESET} from anywhere - ${DIM}${comment}${RESET}"
    else
        echo -e "  ${GREEN}✓${RESET} Port ${BOLD}${p}/${proto}${RESET} from ${BOLD}${from}${RESET} - ${DIM}${comment}${RESET}"
    fi
done

echo ""
log_warn "ATTENTION : assurez-vous que SSH (port ${SSH_NEW_PORT}) est dans la liste"
log_warn "Sinon vous serez DÉCONNECTÉ après activation"
echo ""

if ! ask_yes_no "Appliquer ces règles ?" "y"; then
    log_warn "Configuration annulée"
    exit 0
fi

# Installation si nécessaire
if ! command -v ufw >/dev/null 2>&1; then
    log_step "Installation d'UFW"
    apt update -qq
    apt install -y ufw
    log_success "UFW installé"
fi

# Reset si déjà actif (pour partir d'une base propre)
if ufw status 2>/dev/null | grep -q "Status: active"; then
    log_warn "UFW déjà actif - reset des règles"
    if ask_yes_no "Reset complet de UFW (supprime toutes les règles existantes) ?" "n"; then
        ufw --force reset
        log_success "UFW reset"
    fi
fi

# Définir les politiques
log_step "Définition des politiques par défaut"
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# Ajouter les règles
log_step "Ajout des règles"

for rule in "${ALLOWED_PORTS[@]}"; do
    IFS=':' read -r p proto from comment <<< "${rule}"
    
    if [[ "${from}" == "any" ]]; then
        ufw allow "${p}/${proto}" comment "${comment}" >/dev/null
    else
        ufw allow from "${from}" to any port "${p}" proto "${proto}" comment "${comment}" >/dev/null
    fi
    
    log_success "Règle ajoutée : ${p}/${proto} (${comment})"
done

# Vérifier les règles avant activation
log_step "Vérification des règles AVANT activation"

echo ""
ufw show added | sed 's/^/  /'

echo ""

# Activation
log_step "ACTIVATION DE UFW"

log_warn "Moment critique : activation du pare-feu"
log_warn "Si une règle SSH est manquante, vous perdez l'accès"
echo ""

if ! confirm_critical "Activer UFW maintenant ?"; then
    log_warn "UFW non activé. Pour activer plus tard : sudo ufw enable"
    exit 0
fi

ufw --force enable

if ufw status | grep -q "Status: active"; then
    log_success "UFW est ACTIF"
else
    log_error "UFW n'a pas pu être activé"
    exit 1
fi

# Status final
log_step "Status final UFW"

echo ""
ufw status verbose | sed 's/^/  /'

# Récap
log_section "UFW CONFIGURÉ ET ACTIF"

echo -e "${BOLD}Récapitulatif :${RESET}"
echo -e "  ${CHECK} Default deny incoming"
echo -e "  ${CHECK} Default allow outgoing"
echo -e "  ${CHECK} ${#ALLOWED_PORTS[@]} règles autorisées"
echo -e "  ${CHECK} Mode : ${UFW_MODE}"
[[ "${TAILSCALE_INSTALLED}" == "true" ]] && echo -e "  ${CHECK} SSH limité à Tailscale"
echo ""

log_info "Commandes utiles :"
echo -e "  ${DIM}sudo ufw status verbose${RESET}        # Voir les règles"
echo -e "  ${DIM}sudo ufw allow <port>/tcp${RESET}      # Ajouter une règle"
echo -e "  ${DIM}sudo ufw delete <numéro>${RESET}       # Supprimer une règle"
echo -e "  ${DIM}sudo ufw status numbered${RESET}       # Règles avec numéros"
echo -e "  ${DIM}sudo ufw disable${RESET}               # Désactiver UFW"
echo ""

# Tests recommandés
log_info "Tests recommandés depuis votre Mac/Linux :"
local_ip="$(hostname -I | awk '{print $1}')"
echo -e "  ${DIM}ssh -p ${SSH_NEW_PORT} <user>@${local_ip}${RESET}                  # SSH OK"
echo -e "  ${DIM}nc -zv ${local_ip} 445 2>&1${RESET}                                 # Samba bloqué"
echo -e "  ${DIM}nc -zv ${local_ip} 21 2>&1${RESET}                                  # FTP bloqué"
[[ "${UFW_MODE}" != "strict" ]] && echo -e "  ${DIM}curl -I http://${local_ip}${RESET}                              # HTTP OK"
