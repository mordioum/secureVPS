#!/usr/bin/env bash
# Couleurs et styles pour les sorties terminal
# Source: source lib/colors.sh
#
# Note : les variables ci-dessous sont consommées par les autres fichiers
# sourcés. L'analyse statique sans suivi de sources les voit "unused".
# shellcheck disable=SC2034

# Garde anti double-source : les readonly cassent si le fichier est sourcé deux fois.
if [[ -n "${VPS_SECURE_COLORS_LOADED:-}" ]]; then
    return 0
fi
VPS_SECURE_COLORS_LOADED=1

# Détecte si le terminal supporte les couleurs
if [[ -t 1 ]] && [[ -n "${TERM:-}" ]] && [[ "${TERM}" != "dumb" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly WHITE='\033[1;37m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly RESET='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly WHITE=''
    readonly BOLD=''
    readonly DIM=''
    readonly RESET=''
fi

# Symboles
readonly CHECK="✅"
readonly CROSS="❌"
readonly WARN="⚠️"
readonly INFO="💡"
readonly ROCKET="🚀"
readonly LOCK="🔒"
readonly KEY="🔑"
readonly SHIELD="🛡️"
