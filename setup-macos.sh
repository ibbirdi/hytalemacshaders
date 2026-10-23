#!/bin/bash
# Hytale Mac Shaders: installs (or updates) the shader pack on an Apple Silicon Mac in one command.
#
#   curl -fsSL https://raw.githubusercontent.com/ibbirdi/hytalemacshaders/main/setup-macos.sh | bash
#
# Uninstall:  curl -fsSL https://raw.githubusercontent.com/ibbirdi/hytalemacshaders/main/setup-macos.sh | bash -s -- --uninstall
# Recommended settings again:  ... | bash -s -- --reset-settings
#
# It needs Apple's command line tools (compiler, git, Python), which macOS offers to install, keeps
# its checkout in ~/Library/Application Support/HytaleMacShaders and runs ./install.sh from there.
# Any argument is passed on to ./install.sh.
set -euo pipefail

REPOSITORY="https://github.com/ibbirdi/hytalemacshaders.git"
BRANCH="main"
CHECKOUT="$HOME/Library/Application Support/HytaleMacShaders"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mErreur : %s\033[0m\n' "$*" >&2; exit 1; }

[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail "il faut un Mac Apple Silicon (M1 ou plus récent)."
[[ -d "$HOME/Library/Application Support/Hytale/install" ]] \
    || fail "Hytale n'est pas installé. Installe-le avec le lanceur officiel et lance-le une fois."

if ! xcode-select -p >/dev/null 2>&1; then
    step "Installation des outils de développement d'Apple (une fenêtre macOS va s'ouvrir : clique sur Installer)"
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1; do sleep 5; done
fi

if [[ -d "$CHECKOUT/.git" ]]; then
    step "Mise à jour du pack de shaders"
    git -C "$CHECKOUT" fetch --quiet --depth 1 origin "$BRANCH"
    git -C "$CHECKOUT" reset --quiet --hard FETCH_HEAD
else
    step "Téléchargement du pack de shaders"
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone --quiet --depth 1 --branch "$BRANCH" "$REPOSITORY" "$CHECKOUT"
fi

if pgrep -x HytaleClient >/dev/null; then
    step "Ferme Hytale pour continuer (le lanceur peut rester ouvert)"
    while pgrep -x HytaleClient >/dev/null; do sleep 2; done
fi

step "Installation dans Hytale (compilation et préparation des shaders, une à deux minutes)"
cd "$CHECKOUT"
if ! ./install.sh "$@"; then
    fail "l'installation n'a pas abouti (message ci-dessus).
Le plus souvent, Hytale n'est pas à jour : ouvre le lanceur Hytale, laisse-le mettre le jeu à jour,
lance une partie une fois, ferme le jeu, puis relance cette commande."
fi

step "Terminé"
if [[ " $* " == *" --uninstall "* ]]; then
    echo "Hytale est revenu à son état d'origine."
else
    echo "Lance Hytale avec le lanceur comme d'habitude. fn + ← ouvre le menu des shaders."
    [[ " $* " == *" --reset-settings "* ]] && echo "Les réglages recommandés pour ce Mac sont appliqués (préréglages conservés)."
    echo "Après une mise à jour de Hytale, relance simplement cette même commande."
fi
