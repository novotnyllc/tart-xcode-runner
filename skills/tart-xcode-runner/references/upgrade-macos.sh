#!/bin/zsh
set -eu

if (( EUID != 0 )); then
  password=${TART_XCUI_GUEST_PASSWORD:-admin}
  print -r -- "$password" |
    /usr/bin/sudo -S /usr/bin/env \
      TART_XCUI_GUEST_PASSWORD="$password" /bin/zsh "$0" "$@"
  exit
fi

pkg="/Volumes/My Shared Files/cache/$1"
expected_build=$2
login_user=${TART_XCUI_GUEST_USER:-$(/usr/bin/stat -f %Su /dev/console)}
test -f "$pkg"

if [[ $(/usr/bin/sw_vers -buildVersion) == "$expected_build" ]]; then
  exit 0
fi

/usr/sbin/installer -pkg "$pkg" -target /
installers=(/Applications/Install\ macOS*.app(N))
(( ${#installers} == 1 )) || {
  print -u2 -- "error: expected one macOS installer app, found ${#installers}"
  exit 1
}
print -r -- "${TART_XCUI_GUEST_PASSWORD:-admin}" |
  "${installers[1]}/Contents/Resources/startosinstall" \
    --user "$login_user" \
    --stdinpass \
    --agreetolicense \
    --forcequitapps
