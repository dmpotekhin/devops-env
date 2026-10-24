# devops-env — терминальное окружение (macOS Intel + Ubuntu)

Один скрипт, идемпотентный, ставит Kitty, Zellij, Zsh+Starship, современные CLI,
Yazi, zoxide, git с delta и SSH-подписью.

## Быстрый старт

```bash
# macOS (Intel)
bash ~/devops-env/setup.sh          # установка/докат
bash ~/devops-env/verify.sh         # проверка (63 пункта)

# Ubuntu 26.04 (после копирования каталога devops-env на машину)
bash ~/devops-env/setup.sh
bash ~/devops-env/verify.sh

# ничего не меняя — посмотреть, что будет сделано
bash ~/devops-env/setup.sh --dry-run
DEVENV_OS=linux bash ~/devops-env/setup.sh --dry-run   # прогнать ветку другой ОС
```

## Что делает

| Шаг | macOS | Ubuntu |
|-----|-------|--------|
| Пакеты | готовые darwin-x86_64 бинари с GitHub в `~/.local/bin` (бутылок для macOS 12 Intel нет), cask только для kitty/шрифта | apt (universe) + бинари для того, чего в apt нет |
| Kitty | cask | apt |
| Шрифт | cask `font-jetbrains-mono-nerd-font` | `~/.local/share/fonts` + `fc-cache` |
| Git | сборка 2.56 из исходников, если системный < 2.34 (нужна SSH-подпись) | apt |
| Firewall | — | UFW: deny incoming / allow outgoing |
| Автообновления | — | unattended-upgrades |

## Идемпотентность

- конфиги пишутся только если файла нет (`есть, не трогаю: ...`);
- блок в `~/.zshrc` живёт между `# >>> devops-env >>>` / `# <<< devops-env <<<` и
  перегенерируется целиком — дублей нет (проверено: 1 маркер на файл);
- перед любыми правками dotfiles — бэкап в `~/dotfiles-backup-<timestamp>`.

## Файлы

```
~/.config/kitty/kitty.conf      шрифт, powerline-табы, splits
~/.config/starship.toml         промпт (git, k8s-контекст, venv, cmd_dur)
~/.config/yazi/{yazi,keymap}.toml  трёхпанельный файловый менеджер, z -> zoxide
~/.config/zellij/config.kdl     мультиплексор, vi-режимы
~/.zshrc                        managed-блок: история, PATH, zoxide, y(), алиасы
~/CHEATSHEET.md                 шпаргалка
```

## Известные особенности

- **macOS 12 + Intel**: у большинства проектов больше нет bottle'ов для этой
  платформы → `brew install` собирает Rust-утилиты из исходников часами.
  Поэтому CLI ставятся готовыми бинарями. `eza` собирается из cargo (rustup
  ставится минимальным профилем), `ncdu` — из исходников (C, ~20 c).
- **git < 2.34** не умеет `gpg.format=ssh`: конфиг с SSH-подписью ломает все
  git-команды. Скрипт проверяет версию и включает подпись только если можно.
  На macOS 12 системный git 2.33 → собирается 2.56 в `~/.local/bin`.
- **Yazi + zoxide**: официального пакета-плагина нет, но в Yazi есть встроенный
  preset `zoxide` (бинды `Z`, добавлен `z`). Ему нужна непустая база zoxide —
  достаточно походить по папкам обычным `cd`.
- **Ubuntu 26.04**: терминал по умолчанию Ptyxis, сессия Wayland. Kitty ставится
  и запускается отдельно; буфер обмена Zellij переключается на `wl-copy`
  автоматически (пакет `wl-clipboard`).
