#!/usr/bin/env bash
# devops-env/setup.sh — воспроизводимая настройка терминального окружения.
#   macOS (Intel x86_64) + Ubuntu 26.04 LTS
#
# Идемпотентно: повторный запуск ничего не ломает и не дублирует.
#   - отсутствующее ставится, установленное пропускается;
#   - конфиги пишутся только если их нет (существующие не затираются);
#   - блок в ~/.zshrc перегенерируется между маркерами;
#   - перед перезаписью dotfiles делается бэкап в ~/dotfiles-backup-<ts>.
#
# Использование:  bash ~/devops-env/setup.sh [--dry-run]
set -uo pipefail

DRY=${1:-}
LOG_PREFIX="[devops-env]"
say()  { printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARN: %s\n' "$LOG_PREFIX" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [ "$DRY" = "--dry-run" ]; then say "DRY: $*"; else "$@"; fi; }

BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
case ":$PATH:" in *":$HOME/.cargo/bin:"*) ;; *) export PATH="$HOME/.cargo/bin:$PATH";; esac

OS=other
# DEVENV_OS позволяет прогнать ветку другой ОС в --dry-run (тест скрипта)
case "${DEVENV_OS:-$(uname -s)}" in
  Darwin|mac) OS=mac ;;
  Linux|linux) OS=linux ;;
esac
ARCH=$(uname -m)
say "OS=$OS ARCH=$ARCH"

# ---------------------------------------------------------------- helpers
backup_dotfiles() {
  local ts dir; ts=$(date +%Y%m%d-%H%M%S); dir="$HOME/dotfiles-backup-$ts"
  local any=0
  for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.gitconfig"; do
    [ -f "$f" ] || continue
    mkdir -p "$dir"; cp -a "$f" "$dir"/; any=1
  done
  [ "$any" = 1 ] && say "бэкап dotfiles: $dir"
}

# Скачать URL в файл (только если файла нет)
fetch() { # url dest
  [ -s "$2" ] && return 0
  run curl -fsSL --retry 3 -o "$2" "$1" || { warn "не скачалось: $1"; return 1; }
}

# Развернуть архив и найти в нём нужные бинарники -> $BIN
unpack_bins() { # archive want1[,want2]
  local ar="$1" wants="$2" tmp; tmp=$(mktemp -d)
  case "$ar" in
    *.zip) run unzip -qo "$ar" -d "$tmp" ;;
    *.tar.gz|*.tgz|*.tbz|*.tar.xz) run tar -xf "$ar" -C "$tmp" ;;
    *) run install -m 0755 "$ar" "$BIN/$wants"; rm -rf "$tmp"; return 0 ;;
  esac
  local w found_dir
  for w in $(printf '%s' "$wants" | tr ',' ' '); do
    found_dir=$(find "$tmp" -type f -name "$w" -perm -u+x 2>/dev/null | head -1)
    [ -z "$found_dir" ] && found_dir=$(find "$tmp" -type f -name "$w" 2>/dev/null | head -1)
    if [ -n "$found_dir" ]; then
      run install -m 0755 "$found_dir" "$BIN/$w"
    else
      warn "бинарник $w не найден в $ar"
    fi
  done
  rm -rf "$tmp"
}

gh() { # repo tag asset wants
  local repo="$1" tag="$2" asset="$3" wants="$4" tmp
  tmp=$(mktemp -d)/"$asset"
  fetch "https://github.com/$repo/releases/download/$tag/$asset" "$tmp" || return 1
  unpack_bins "$tmp" "$wants"
  rm -f "$tmp"
}

# Ставим из GitHub только если бинарника нет
need_bin() { # cmd
  ! have "$1"
}

install_zsh_plugins() {
  local base="$HOME/.zsh/plugins" r n
  mkdir -p "$base"
  for r in zsh-users/zsh-autosuggestions zsh-users/zsh-syntax-highlighting Aloxaf/fzf-tab; do
    n="${r#*/}"
    if [ -d "$base/$n/.git" ]; then
      run git -C "$base/$n" pull -q --ff-only || warn "не обновился $n"
    else
      run git clone -q --depth 1 "https://github.com/$r.git" "$base/$n"
    fi
  done
}

install_rust_if_needed() {
  have cargo && return 0
  say "ставлю Rust (rustup, минимальный профиль)"
  local tmp; tmp=$(mktemp -d)
  fetch "https://static.rust-lang.org/rustup/dist/${ARCH}-apple-$( [ "$OS" = mac ] && echo darwin || echo unknown-linux-gnu )/rustup-init" "$tmp/rustup-init" \
    || fetch "https://sh.rustup.rs" "$tmp/rustup-init"
  run chmod +x "$tmp/rustup-init"
  run "$tmp/rustup-init" -y --profile minimal --default-toolchain stable --no-modify-path
}

# git >= 2.34 нужен для SSH-подписи. На macOS 12 системный git 2.33 => собираем.
git_ver_ok() {
  local v; v=$(git --version 2>/dev/null | awk '{print $3}')
  [ -n "${v:-}" ] && [ "$(printf '2.34\n%s\n' "$v" | sort -V | head -1)" = "2.34" ]
}
build_git_from_source() {
  git_ver_ok && return 0
  local ver=2.56.0 tmp sdk
  sdk=$(xcrun --show-sdk-path 2>/dev/null || true)
  tmp=$(mktemp -d)
  say "собираю git $ver в ~/.local (системный git $(git --version | awk '{print $3}') не умеет SSH-подпись)"
  fetch "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$ver.tar.gz" "$tmp/git.tgz" || { warn "не скачался git"; return 1; }
  run tar -xf "$tmp/git.tgz" -C "$tmp"
  ( cd "$tmp/git-$ver" && \
    run make -j6 prefix="$HOME/.local" NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 ${sdk:+-I"$sdk/usr/include"} && \
    run make prefix="$HOME/.local" NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 install ) \
    || { warn "git не собрался — SSH-подпись будет пропущена"; return 1; }
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- macOS
setup_mac() {
  if have brew; then
    local pfx; pfx=$(brew --prefix)
    case "$pfx" in
      /usr/local) say "Homebrew: Intel-префикс /usr/local (ok)" ;;
      /opt/homebrew) warn "Homebrew стоит по Apple Silicon пути ($pfx), а машина $ARCH — переустанови Homebrew в /usr/local!" ;;
    esac
  else
    say "ставлю Homebrew для Intel (/usr/local)"
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  # Cask'и — это готовые .app/.ttf, компиляции нет (безопасно на Intel/macOS 12)
  for c in kitty font-jetbrains-mono-nerd-font; do
    if brew list --cask 2>/dev/null | grep -qx "$c"; then say "cask $c уже есть"; else run brew install --cask "$c"; fi
  done
  [ -e "$BIN/kitty" ] || run ln -sf /Applications/kitty.app/Contents/MacOS/kitty "$BIN/kitty"

  # git >= 2.34 нужен для SSH-подписи коммитов (macOS 12 несёт git 2.33)
  build_git_from_source

  # ВНИМАНИЕ: на macOS 12 (Monterey) Intel у Homebrew нет бутылок => brew install
  # компилирует из исходников (rustc часами). Поэтому CLI — prebuilt с GitHub.
  need_bin rg      && gh BurntSushi/ripgrep 15.2.0   ripgrep-15.2.0-x86_64-apple-darwin.tar.gz rg
  need_bin fd      && gh sharkdp/fd        v10.5.0   fd-v10.5.0-x86_64-apple-darwin.tar.gz fd
  need_bin bat     && gh sharkdp/bat       v0.26.1   bat-v0.26.1-x86_64-apple-darwin.tar.gz bat
  need_bin fzf     && gh junegunn/fzf      v0.74.5   fzf-0.74.5-darwin_amd64.tar.gz fzf
  need_bin delta   && gh dandavison/delta  0.18.2    delta-0.18.2-x86_64-apple-darwin.tar.gz delta
  need_bin jq      && gh jqlang/jq         jq-1.8.2  jq-macos-amd64 jq
  need_bin yq      && gh mikefarah/yq      v4.54.1   yq_darwin_amd64 yq
  need_bin btop    && gh aristocratos/btop v1.2.13   btop-x86_64-macos-monterey.tbz btop
  need_bin tldr    && gh dbrgn/tealdeer    v1.9.0    tealdeer-macos-x86_64 tldr
  need_bin direnv  && gh direnv/direnv     v2.38.2   direnv.darwin-amd64 direnv
  need_bin just    && gh casey/just        1.59.0    just-1.59.0-x86_64-apple-darwin.tar.gz just
  need_bin dust    && gh bootandy/dust     v1.2.6    dust-v1.2.6-x86_64-apple-darwin.tar.gz dust
  need_bin procs   && gh dalance/procs     v0.14.12  procs-v0.14.12-x86_64-mac.zip procs
  need_bin yazi    && gh sxyazi/yazi       v26.9.1   yazi-x86_64-apple-darwin.zip yazi,ya
  need_bin zoxide  && gh ajeetdsouza/zoxide v0.10.0  zoxide-0.10.0-x86_64-apple-darwin.tar.gz zoxide
  need_bin starship && gh starship/starship v1.27.0  starship-x86_64-apple-darwin.tar.gz starship
  need_bin zellij  && gh zellij-org/zellij  v0.45.1  zellij-x86_64-apple-darwin.tar.gz zellij
  need_bin k9s     && gh derailed/k9s      v0.51.0  k9s_Darwin_amd64.tar.gz k9s

  if need_bin helm; then
    local t; t=$(mktemp -d)/helm.tgz
    if fetch https://get.helm.sh/helm-v3.16.3-darwin-amd64.tar.gz "$t"; then
      unpack_bins "$t" helm; rm -f "$t"
    fi
  fi
  if need_bin kubectx; then
    fetch https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx "$BIN/kubectx" && run chmod +x "$BIN/kubectx"
  fi
  if need_bin kubens; then
    fetch https://raw.githubusercontent.com/ahmetb/kubectx/master/kubens "$BIN/kubens" && run chmod +x "$BIN/kubens"
  fi
  if need_bin mas; then
    local z; z=$(mktemp -d)/mas.zip
    if fetch https://github.com/mas-cli/mas/releases/download/v1.8.1/mas.xcarchive.zip "$z"; then
      local d; d=$(mktemp -d); run unzip -qo "$z" -d "$d"
      run mkdir -p "$HOME/.local/opt/mas"
      [ -d "$d/mas.xcarchive/Products/bin" ] && run cp -R "$d/mas.xcarchive/Products/bin" "$HOME/.local/opt/mas/"
      [ -d "$d/mas.xcarchive/Products/Frameworks" ] && run cp -R "$d/mas.xcarchive/Products/Frameworks" "$HOME/.local/opt/mas/"
      run chmod +x "$HOME/.local/opt/mas/bin/mas"
      run ln -sf "$HOME/.local/opt/mas/bin/mas" "$BIN/mas"
      rm -rf "$d" "$z"
    fi
  fi

  # eza: macOS-бинарей не публикует -> сборка из cargo
  if need_bin eza; then
    install_rust_if_needed
    if have cargo || [ -x "$HOME/.cargo/bin/cargo" ]; then
      say "собираю eza через cargo (2-4 мин)"
      run "$HOME/.cargo/bin/cargo" install eza --locked || warn "eza не собрался"
    fi
  fi
  [ -f "$HOME/.cargo/bin/eza" ] && [ ! -f "$BIN/eza" ] && run ln -sf "$HOME/.cargo/bin/eza" "$BIN/eza"

  # ncdu: официальных macOS-бинарей нет -> сборка из исходников (C, ~20 c)
  if need_bin ncdu; then
    local t; t=$(mktemp -d)
    if fetch https://dev.yorhel.nl/download/ncdu-1.21.tar.gz "$t/ncdu.tgz"; then
      run tar -xf "$t/ncdu.tgz" -C "$t"
      ( cd "$t/ncdu-1.21" && run ./configure --prefix="$HOME/.local" && run make -j4 && run install -m 0755 ncdu "$BIN/ncdu" ) \
        || warn "ncdu не собрался (нужен Xcode CLT: xcode-select --install)"
    fi
  fi
}

# ---------------------------------------------------------------- Ubuntu
setup_linux() {
  local SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  say "apt update"
  run $SUDO apt-get update -qq

  # базовое из репозиториев (нативные пакеты, не snap).
  # ВАЖНО: в списке только то, что реально есть в universe Ubuntu —
  # иначе apt-get install падает ЦЕЛИКОМ и kitty/ripgrep не ставятся.
  local pkgs="zsh curl git unzip fontconfig ripgrep fd-find bat fzf git-delta \
jq btop ncdu direnv zoxide eza tree tmux kitty wl-clipboard ca-certificates build-essential"
  say "apt install базовых пакетов"
  run $SUDO apt-get install -y -qq $pkgs || {
    warn "часть пакетов недоступна — добираю по одному"
    for p in $pkgs; do run $SUDO apt-get install -y -qq "$p" || warn "нет в apt: $p"; done
  }

  # ufw на чистой системе может отсутствовать
  if need_bin ufw; then run $SUDO apt-get install -y -qq ufw; fi

  # Debian/Ubuntu переименовывают бинарники
  need_bin fd  && [ -x /usr/bin/fdfind ] && run ln -sf /usr/bin/fdfind "$BIN/fd"
  need_bin bat && [ -x /usr/bin/batcat ] && run ln -sf /usr/bin/batcat "$BIN/bat"

  # официальный установщик starship (если в apt не было)
  if need_bin starship; then
    run curl -fsSL https://starship.rs/install.sh -o /tmp/starship-install.sh
    run sh /tmp/starship-install.sh -y --bin-dir "$BIN" || warn "starship не установился"
  fi

  # prebuilt с GitHub, если apt не дал
  need_bin tldr   && gh dbrgn/tealdeer    v1.9.0  tealdeer-linux-x86_64-musl tldr
  need_bin dust   && gh bootandy/dust     v1.2.6  dust-v1.2.6-x86_64-unknown-linux-musl.tar.gz dust
  need_bin procs  && gh dalance/procs     v0.14.12 procs-v0.14.12-x86_64-linux.zip procs
  need_bin zellij && gh zellij-org/zellij v0.45.1 zellij-x86_64-unknown-linux-musl.tar.gz zellij
  need_bin yazi   && gh sxyazi/yazi       v26.9.1 yazi-x86_64-unknown-linux-musl.zip yazi,ya
  need_bin just   && gh casey/just        1.59.0  just-1.59.0-x86_64-unknown-linux-musl.tar.gz just
  need_bin yq     && gh mikefarah/yq      v4.54.1 yq_linux_amd64 yq
  need_bin k9s    && gh derailed/k9s      v0.51.0 k9s_Linux_amd64.tar.gz k9s
  need_bin eza    && { install_rust_if_needed; run "$HOME/.cargo/bin/cargo" install eza --locked; }
  need_bin helm   && { local t; t=$(mktemp -d)/helm.tgz; fetch https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz "$t" && unpack_bins "$t" helm; }
  need_bin kubectx && { fetch https://raw.githubusercontent.com/ahmetb/kubectx/master/kubectx "$BIN/kubectx" && run chmod +x "$BIN/kubectx"; }
  need_bin kubens  && { fetch https://raw.githubusercontent.com/ahmetb/kubectx/master/kubens  "$BIN/kubens"  && run chmod +x "$BIN/kubens"; }

  # Nerd Font (в apt его нет)
  local fdir="$HOME/.local/share/fonts"
  if ! fc-list 2>/dev/null | grep -qi "JetBrainsMono"; then
    say "ставлю JetBrains Mono Nerd Font в $fdir"
    run mkdir -p "$fdir"
    local fz; fz=$(mktemp -d)/jbm.zip
    if fetch https://github.com/ryanoasis/nerd-fonts/releases/download/v3.2.1/JetBrainsMono.zip "$fz"; then
      run unzip -qo "$fz" -d "$fdir" && run fc-cache -f "$fdir" >/dev/null
    fi
  else
    say "Nerd Font уже установлен"
  fi

  # Firewall: deny incoming / allow outgoing
  if have ufw || [ "$DRY" = "--dry-run" ]; then
    say "настраиваю UFW"
    run $SUDO ufw --force default deny incoming
    run $SUDO ufw --force default allow outgoing
    run $SUDO ufw --force enable
    run $SUDO systemctl enable --now ufw
  fi
  # Автоматические security updates
  say "включаю unattended-upgrades"
  run $SUDO apt-get install -y -qq unattended-upgrades
  echo 'APT::Periodic::Update-Package-Lists "1";' | run $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  echo 'APT::Periodic::Unattended-Upgrade "1";'     | run $SUDO tee -a /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
  run $SUDO systemctl enable --now unattended-upgrades 2>/dev/null || true

  # zsh как логин-шелл
  if command -v getent >/dev/null && [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    run chsh -s "$(command -v zsh)" || warn "chsh не выполнен — смени шелл вручную"
  fi
  say "Wayland/Ptyxis: Kitty ставится отдельно и запускается из меню как 'kitty';"
  say "  при проблемах с вводом под Wayland добавь в /etc/environment: GDK_BACKEND=x11"
}

# ---------------------------------------------------------------- common configs
write_if_absent() { # path
  if [ -e "$1" ]; then say "есть, не трогаю: ${1#$HOME/}"; return 0; fi
  run mkdir -p "$(dirname "$1")"
  say "создаю ${1#$HOME/}"
  run tee "$1" >/dev/null
}

setup_common() {
  backup_dotfiles
  install_zsh_plugins

  # --- kitty ---
  if [ ! -f "$HOME/.config/kitty/kitty.conf" ]; then
    run mkdir -p "$HOME/.config/kitty"
    run tee "$HOME/.config/kitty/kitty.conf" >/dev/null <<'KITTY'
font_family      JetBrainsMono NF
font_size        12
window_padding_width 6
tab_bar_style    powerline
tab_bar_edge     bottom
enable_audio_bell no
scrollback_lines 10000
copy_on_select   yes
allow_remote_control yes
enabled_layouts  splits,tall,grid
confirm_os_window_close 0
map ctrl+shift+enter launch --location=vsplit --cwd=current
map ctrl+shift+minus launch --location=hsplit --cwd=current
map ctrl+shift+left_bracket  previous_window
map ctrl+shift+right_bracket next_window
map ctrl+shift+w close_window
KITTY
  else
    say "есть, не трогаю: .config/kitty/kitty.conf"
  fi

  # --- starship ---
  if [ ! -f "$HOME/.config/starship.toml" ]; then
    run mkdir -p "$HOME/.config"
    run tee "$HOME/.config/starship.toml" >/dev/null <<'STAR'
add_newline = true
format = """
[](fg:#7c9cff bg:#1b2228)\
[ ](fg:#cdd6f4 bg:#1b2228)\
$directory$git_branch$git_status$kubernetes$python\
[](fg:#1b2228 bg:#7c9cff)\
[](fg:#0d1117)\
$cmd_duration$status\
"""
right_format = """$time"""
[directory]
style = "fg:#cdd6f4 bg:#1b2228"
format = "[ $path ]($style)"
truncation_length = 3
truncation_symbol = "…/"
[git_branch]
style = "fg:#1b2228 bg:#a6e3a1"
format = "[ $branch ]($style)"
[git_status]
style = "fg:#1b2228 bg:#f9e2af"
format = "[$all_status$ahead_behind ]($style)"
[kubernetes]
disabled = false
format = "[ $context(:$namespace) ]($style)"
style = "fg:#1b2228 bg:#89b4fa"
[[kubernetes.contexts]]
context_pattern = ".*prod.*"
style = "fg:#ffffff bg:#f38ba8 bold"
[python]
format = "[ ${symbol}${pyenv_prefix}(${version}) ]($style)"
style = "fg:#1b2228 bg:#f5c2e7"
[cmd_duration]
min_time = 2000
format = "[ took $duration ](fg:#1b2228 bg:#fab387)"
[status]
style = "fg:#1b2228 bg:#f38ba8"
format = "[ $status ]($style)"
disabled = false
[time]
disabled = false
style = "fg:#6c7086"
format = "[$time]($style)"
time_format = "%H:%M"
STAR
  else
    say "есть, не трогаю: .config/starship.toml"
  fi

  # --- yazi keymap ---
  # zoxide в Yazi — ВСТРОЕННЫЙ preset-плагин (zoxide query -i + fzf);
  # свой .lua не нужен, дефолтный бинд — Z, добавляем ещё z.
  if [ ! -f "$HOME/.config/yazi/keymap.toml" ]; then
    run mkdir -p "$HOME/.config/yazi"
    run tee "$HOME/.config/yazi/keymap.toml" >/dev/null <<'YAKEY'
[mgr]
prepend_keymap = [
  { on = "z", run = "plugin zoxide", desc = "zoxide: перейти в папку" },
  { on = "~", run = "cd ~", desc = "Домой" },
  { on = "<C-d>", run = "cd ~/Downloads", desc = "Downloads" },
  { on = "<C-h>", run = "set show_hidden", desc = "Скрытые файлы" },
]

[confirm]
prepend_keymap = [
  { on = "<Esc>", run = "close", desc = "Отмена" },
]
YAKEY
  else
    say "есть, не трогаю: .config/yazi/keymap.toml"
  fi

  # --- zellij ---
  if [ ! -f "$HOME/.config/zellij/config.kdl" ]; then
    run mkdir -p "$HOME/.config/zellij"
    run tee "$HOME/.config/zellij/config.kdl" >/dev/null <<'ZJ'
// Zellij — managed by devops-env setup (idempotent)
default_shell "zsh"
default_mode "normal"
mouse_mode true
copy_command "pbcopy"
copy_clipboard "system"
scroll_buffer_size 10000
show_startup_tips false
show_release_notes false

theme "catppuccin-mocha"
themes {
    catppuccin-mocha {
        fg "#cdd6f4"
        bg "#1e1e2e"
        black "#45475a"
        red "#f38ba8"
        green "#a6e3a1"
        yellow "#f9e2af"
        blue "#89b4fa"
        magenta "#f5c2e7"
        cyan "#94e2d5"
        white "#bac2de"
        orange "#fab387"
    }
}

keybinds {
    normal {
        bind "Alt Left"  { MoveFocus "Left"; }
        bind "Alt Right" { MoveFocus "Right"; }
        bind "Alt Up"    { MoveFocus "Up"; }
        bind "Alt Down"  { MoveFocus "Down"; }
        bind "Alt n" { NewPane "Down"; SwitchToMode "Normal"; }
        bind "Alt m" { NewPane "Right"; SwitchToMode "Normal"; }
        bind "Alt x" { CloseFocus; SwitchToMode "Normal"; }
        bind "Alt t" { NewTab; SwitchToMode "Normal"; }
        bind "Alt f" { ToggleFloatingPanes; SwitchToMode "Normal"; }
    }
    scroll {
        bind "y" { Copy; SwitchToMode "Normal"; }
    }
}
ZJ
  else
    say "есть, не трогаю: .config/zellij/config.kdl"
  fi
  # Linux: системный буфер другой, pbcopy там нет
  if [ "$OS" = linux ]; then
    if have wl-copy; then
      run sed -i 's/^copy_command .*/copy_command "wl-copy"/' "$HOME/.config/zellij/config.kdl" 2>/dev/null || true
    elif have xclip; then
      run sed -i 's/^copy_command .*/copy_command "xclip -selection clipboard"/' "$HOME/.config/zellij/config.kdl" 2>/dev/null || true
    fi
  fi

  # --- git ---
  run git config --global core.pager delta
  run git config --global core.autocrlf false
  run git config --global fetch.prune true
  run git config --global rebase.autosquash true
  run git config --global interactive.diffFilter "delta --color-only"
  run git config --global delta.navigate true
  run git config --global delta.line-numbers true
  run git config --global merge.conflictStyle zdiff3

  # SSH-подпись коммитов требует git >= 2.34; на старом git конфиг gpg.format=ssh
  # делает НЕВАЛИДНЫМ весь конфиг (падает любая git-команда) — проверяем версию.
  if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    if [ "$DRY" = "--dry-run" ] || git_ver_ok; then
      run git config --global gpg.format ssh
      run git config --global user.signingkey "$HOME/.ssh/id_ed25519.pub"
      run git config --global commit.gpgsign true
      run git config --global tag.gpgsign true
      # чтобы `git log --show-signature` мог проверять свои же подписи
      if [ ! -f "$HOME/.ssh/allowed_signers" ]; then
        local em; em=$(git config --global user.email)
        [ -n "$em" ] || em=$(whoami)
        run bash -c "printf '%s %s\n' '$em' \"\$(cut -d' ' -f1,2 $HOME/.ssh/id_ed25519.pub)\" > $HOME/.ssh/allowed_signers"
      fi
      run git config --global gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
      say "git: подпись коммитов SSH-ключом включена"
    else
      say "git $(git --version | awk '{print $3}') < 2.34 — SSH-подпись не поддерживается, пропускаю (нужен git из ~/.local/bin)"
    fi
  else
    say "git: SSH-ключа нет — подпись коммитов пропущена"
  fi

  # --- .zshrc managed block ---
  if [ "$DRY" != "--dry-run" ]; then
    python3 - "$HOME/.zshrc" "$OS" <<'PYZSH'
import sys, os
path, os_name = sys.argv[1], sys.argv[2]
START, END = "# >>> devops-env >>>", "# <<< devops-env <<<"
block = START + r'''
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
export EDITOR="${EDITOR:-vim}"
export VISUAL="$EDITOR"
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_DUPS HIST_REDUCE_BLANKS
setopt EXTENDED_GLOB AUTO_CD INTERACTIVE_COMMENTS NO_BEEP
autoload -Uz compinit
if [[ -n ${ZDOTDIR:-$HOME}/.zcompdump(#qN.mh+24) ]]; then compinit; else compinit -C; fi
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh) 2>/dev/null || true
  export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --exclude .git'
fi
[ -f "$HOME/.zsh/plugins/fzf-tab/fzf-tab.zsh" ] && source "$HOME/.zsh/plugins/fzf-tab/fzf-tab.zsh"
[ -f "$HOME/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ] && source "$HOME/.zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=#6c7086'
[ -f "$HOME/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && source "$HOME/.zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
command -v zoxide   >/dev/null 2>&1 && eval "$(zoxide init zsh)"
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
command -v direnv   >/dev/null 2>&1 && eval "$(direnv hook zsh)"
y() {
  local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
  yazi "$@" --cwd-file="$tmp"
  if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
    builtin cd -- "$cwd"
  fi
  rm -f -- "$tmp"
}
alias ll='eza -alF --icons --group-directories-first'
alias la='eza -a --icons --group-directories-first'
alias lt='eza --tree --level=2 --icons'
alias gs='git status'
alias gd='git diff'
alias gc='git commit'
alias gp='git push'
alias gl='git pull'
alias k='kubectl'
alias kn='kubens'
alias kx='kubectx'
alias cat='bat --paging=never'
alias top='btop'
alias zj='zellij'
alias ports='procs'
''' + END + "\n"
src = open(path).read() if os.path.exists(path) else ""
if START in src:
    head = src.split(START)[0].rstrip("\n")
    tail = src.split(END)[-1] if END in src else ""
    new = head + "\n\n" + block + tail
else:
    new = (src.rstrip("\n") + "\n\n" if src.strip() else "") + block
open(path, "w").write(new)
print("[devops-env] .zshrc обновлён:", path)
PYZSH
  fi

  # --- cheatsheet ---
  if [ ! -f "$HOME/CHEATSHEET.md" ]; then
    say "CHEATSHEET.md отсутствует — сгенерируется при первом запуске из репозитория"
  else
    say "есть: ~/CHEATSHEET.md"
  fi
}

# ---------------------------------------------------------------- main
case "$OS" in
  mac)   setup_mac ;;
  linux) setup_linux ;;
  *)     warn "неизвестная ОС — только общие конфиги" ;;
esac
setup_common

say "готово. Проверка: bash ~/devops-env/verify.sh"
say "Открой новый терминал (или: exec zsh) — промпт starship, zoxide, Yazi."
