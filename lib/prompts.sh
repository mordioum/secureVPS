#!/usr/bin/env bash
# Fonctions de questions interactives
# Source: source lib/prompts.sh

# Demande oui/non
# Usage: ask_yes_no "Question ?" "y"  (default y or n)
# Returns: 0 if yes, 1 if no
ask_yes_no() {
    local question="$1"
    local default="${2:-n}"
    local prompt
    local answer
    
    if [[ "${default}" == "y" ]]; then
        prompt="${question} ${BOLD}[O/n]${RESET} "
    else
        prompt="${question} ${BOLD}[o/N]${RESET} "
    fi
    
    while true; do
        # shellcheck disable=SC2059
        printf "${prompt}"
        read -r answer
        answer="${answer:-${default}}"
        case "${answer,,}" in
            y|yes|o|oui) return 0 ;;
            n|no|non) return 1 ;;
            *) echo "Répondez par O (oui) ou N (non)" ;;
        esac
    done
}

# Demande une valeur texte
# Usage: ask_input "Question" "default_value" "validation_function"
ask_input() {
    # Cette fonction est appelée via $(ask_input ...) — donc seule la valeur
    # finale doit aller sur stdout. Les prompts vont sur stderr (>&2), sinon
    # ils seraient capturés et concaténés à la valeur (bug B8).
    local question="$1"
    local default="${2:-}"
    local validator="${3:-}"
    local answer

    while true; do
        if [[ -n "${default}" ]]; then
            # shellcheck disable=SC2059
            printf "%b%s%b ${DIM}(défaut: %s)${RESET}: " "${BOLD}" "${question}" "${RESET}" "${default}" >&2
        else
            printf "%b%s%b: " "${BOLD}" "${question}" "${RESET}" >&2
        fi

        read -r answer
        answer="${answer:-${default}}"

        # Si pas de validation, on accepte
        if [[ -z "${validator}" ]]; then
            echo "${answer}"
            return 0
        fi

        # Sinon, on valide avec la fonction fournie
        if "${validator}" "${answer}"; then
            echo "${answer}"
            return 0
        else
            log_error "Valeur invalide. Veuillez réessayer."
        fi
    done
}

# Demande un mot de passe (caché)
# Idem ask_input : prompts sur stderr, valeur sur stdout (capturable via $()).
ask_password() {
    local question="$1"
    local password

    printf "%b%s%b: " "${BOLD}" "${question}" "${RESET}" >&2
    read -rs password
    echo >&2  # nouvelle ligne après l'input caché (sur stderr, pas capturée)
    echo "${password}"
}

# Demande un choix parmi plusieurs options
# Usage: ask_choice "Question" "option1" "option2" "option3"
# Retourne le numéro choisi (1-based)
ask_choice() {
    local question="$1"
    shift
    local options=("$@")
    local count="${#options[@]}"
    local choice
    
    echo ""
    echo -e "${BOLD}${question}${RESET}"
    echo ""
    
    local i=1
    for opt in "${options[@]}"; do
        echo "  ${BOLD}${i})${RESET} ${opt}"
        ((i++))
    done
    echo ""
    
    while true; do
        printf "%bVotre choix [1-%d]:%b " "${BOLD}" "${count}" "${RESET}"
        read -r choice
        
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [[ "${choice}" -ge 1 ]] && [[ "${choice}" -le "${count}" ]]; then
            return "${choice}"
        else
            log_error "Choix invalide. Entrez un nombre entre 1 et ${count}."
        fi
    done
}

# Demande confirmation avant une action critique
# Usage: confirm_critical "Action description"
# Returns: 0 if confirmed, 1 if cancelled
confirm_critical() {
    local action="$1"
    
    echo ""
    echo -e "${YELLOW}${WARN} ATTENTION - Action critique${RESET}"
    echo -e "${WHITE}${action}${RESET}"
    echo ""
    
    if ask_yes_no "Êtes-vous SÛR de vouloir continuer ?" "n"; then
        return 0
    else
        log_warn "Action annulée par l'utilisateur"
        return 1
    fi
}

# Pause - attend une touche
press_any_key() {
    local message="${1:-Appuyez sur Entrée pour continuer...}"
    echo ""
    printf "%b%s%b" "${DIM}" "${message}" "${RESET}"
    read -r
}

# Affiche un récap et demande confirmation
# Usage: show_summary_and_confirm "title" "key1=val1" "key2=val2" ...
show_summary_and_confirm() {
    local title="$1"
    shift
    
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
    printf "${CYAN}${BOLD}║${RESET}  %-60s ${CYAN}${BOLD}║${RESET}\n" "${title}"
    echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════════════════╣${RESET}"
    
    for item in "$@"; do
        local key="${item%%=*}"
        local val="${item#*=}"
        printf "${CYAN}${BOLD}║${RESET}  %-20s : %-37s ${CYAN}${BOLD}║${RESET}\n" "${key}" "${val}"
    done
    
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    if ask_yes_no "Confirmer ces paramètres ?" "y"; then
        return 0
    else
        return 1
    fi
}
