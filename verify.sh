#!/usr/bin/env bash
# verify.sh — проверка окружения. Ничего не меняет, только проверяет.
# Код возврата: 0 — всё критичное на месте, 1 — есть провалы.
set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
chk() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

# инструмент -> команда для версии (пусто = только наличие)
ver_of() {
  case "$1" in
    kitty)     kitty --version 2>&1 | head -1 ;;
    zsh)       zsh --version 2>&1 ;;
    starship)  starship --version 2>&1 ;;
    rg)        rg --version 2>&1 | head -1 ;;
    fd)        fd --version 2>&1 ;;
    bat)       bat --version 2>&1 | head -1 ;;
    eza)       eza --version 2>&1 | head -1 ;;
    fzf)       fzf --version 2>&1 ;;
    delta)     delta --version 2>&1 ;;
    jq)        jq --version 2>&1 ;;
    yq)        yq --version 2>&1 ;;
    btop)      btop --version 2>&1 ;;
    ncdu)      ncdu --version 2>&1 | head -1 ;;
    tldr)      tldr --version 2>&1 | head -1 ;;
    direnv)    direnv version 2>&1 ;;
    just)      just --version 2>&1 ;;
    dust)      dust --version 2>&1 ;;
    procs)     procs --version 2>&1 | head -1 ;;
    yazi)      yazi --version 2>&1 | head -1 ;;
    zoxide)    zoxide --version 2>&1 ;;
    zellij)    zellij --version 2>&1 ;;
    helm)      helm version --short 2>&1 ;;
    k9s)       k9s version -s 2>&1 | head -1 ;;
    kubectl)   kubectl version --client 2>&1 | head -1 ;;
    git)       git --version 2>&1 ;;
    mas)       mas version 2>&1 ;;
    *)         echo "установлен" ;;
  esac
}

echo "== Система =="
printf '  arch: %s | os: %s\n' "$(uname -m)" "$(uname -s)"
if [ "$(uname -s)" = Darwin ]; then
  printf '  macos: %s\n' "$(sw_vers -productVersion)"
  printf '  brew:  %s (prefix %s)\n' "$(command -v brew || echo нет)" "$(brew --prefix 2>/dev/null || echo -)"
  [ "$(uname -m)" = x86_64 ]; chk "Intel x86_64" $?
  [ "$(brew --prefix 2>/dev/null)" = /usr/local ]; chk "Homebrew в /usr/local (Intel-префикс)" $?
  [ -x /Applications/kitty.app/Contents/MacOS/kitty ]; chk "Kitty.app установлен" $?
  ls "$HOME/Library/Fonts" 2>/dev/null | grep -qi jetbrainsmono; chk "JetBrains Mono Nerd Font установлен" $?
else
  printf '  release: %s\n' "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  command -v ufw >/dev/null && { ufw status 2>/dev/null | head -1; }
  dpkg -l unattended-upgrades 2>/dev/null | grep -q ^ii; chk "unattended-upgrades установлен" $?
fi

echo "== Инструменты =="
for t in git kitty zsh starship rg fd bat eza fzf delta jq yq btop ncdu tldr direnv just dust procs yazi zoxide zellij helm kubectx kubens k9s mas; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %-9s %s\n' "$t" "$(ver_of "$t" | cut -c1-58)"
    PASS=$((PASS+1))
  else
    bad "$t — НЕ НАЙДЕН"
  fi
done

echo "== Shell =="
[ "$(basename "$SHELL")" = zsh ]; chk "SHELL = zsh ($SHELL)" $?
zsh -ic 'true' >/dev/null 2>&1; chk ".zshrc загружается без ошибок" $?
zsh -ic 'type y >/dev/null 2>&1' >/dev/null 2>&1; chk "функция y() (Yazi + возврат cwd) определена" $?
zsh -ic 'alias ll >/dev/null 2>&1' >/dev/null 2>&1; chk "алиасы (ll, gs, gd, k, kx, kn) загружены" $?
zsh -ic 'command -v zoxide >/dev/null && command -v starship >/dev/null' >/dev/null 2>&1; chk "zoxide и starship доступны в zsh" $?

echo "== Git =="
for kv in "core.pager:delta" "core.autocrlf:false" "fetch.prune:true" "rebase.autosquash:true"; do
  k=${kv%%:*}; want=${kv##*:}; got=$(git config --global --get "$k")
  if [ "$got" = "$want" ]; then ok "git $k = $want"; else bad "git $k = '${got}' (ожидалось $want)"; fi
done
if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
  [ "$(git config --global --get commit.gpgsign)" = true ]; chk "подпись коммитов SSH-ключом (id_ed25519)" $?
fi

echo "== Конфиги =="
for f in .config/kitty/kitty.conf .config/starship.toml .config/yazi/keymap.toml \
         .config/yazi/yazi.toml .config/zellij/config.kdl; do
  [ -f "$HOME/$f" ]; chk "$f" $?
done
grep -q 'plugin zoxide' "$HOME/.config/yazi/keymap.toml"; chk "yazi: z -> встроенный плагин zoxide" $?
grep -q 'devops-env' "$HOME/.zshrc"; chk ".zshrc содержит managed-блок (идемпотентный)" $?
grep -qx 'font_family      JetBrainsMono NF' "$HOME/.config/kitty/kitty.conf"; chk "kitty: шрифт JetBrainsMono NF" $?
grep -q 'tab_bar_edge' "$HOME/.config/kitty/kitty.conf"; chk "kitty: powerline-табы снизу" $?
grep -q 'savehist' /dev/null 2>/dev/null || true
zsh -ic 'echo $HISTSIZE' 2>/dev/null | grep -qx 100000; chk "история zsh = 100000" $?

echo "== Функционал =="
d=$(mktemp -d); mkdir -p "$d/aaa/bbb"
zoxide add "$d/aaa/bbb" >/dev/null 2>&1; chk "zoxide add работает" $?
if zsh -ic "z '$d/aaa/bbb' >/dev/null 2>&1; pwd" 2>/dev/null | grep -qx "$d/aaa/bbb"; then
  ok "z <путь> реально переносит в папку"
else
  bad "z <путь> не сработал"
fi
rm -rf "$d"
if command -v yazi >/dev/null && zsh -ic 'whence -w y' 2>/dev/null | grep -q function; then
  ok "y() — обёртка Yazi с возвратом в cwd"
else
  bad "y() не определена как функция"
fi
[ -f "$HOME/CHEATSHEET.md" ]; chk "~/CHEATSHEET.md создан" $?
for s in "Навигация (zoxide)" "Файловый менеджер (Yazi)" "Поиск" "Просмотр файлов" "Git" "Kubernetes" "Терминал Kitty" "Полезные утилиты"; do
  grep -qF -- "$s" "$HOME/CHEATSHEET.md" 2>/dev/null; chk "CHEATSHEET: раздел $s" $?
done

echo
printf 'ИТОГО: %d ok, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
