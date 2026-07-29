#!/bin/zsh
set -eu

runner="/Volumes/My Shared Files"
cache="$runner/cache"
references="$runner/references"
login_user=${TART_XCUI_GUEST_USER:-$(/usr/bin/stat -f %Su /dev/console)}
login_uid=$(/usr/bin/id -u "$login_user")
login_password=${TART_XCUI_GUEST_PASSWORD:-admin}

if (( EUID != 0 )); then
  print -r -- "$login_password" |
    /usr/bin/sudo -S /usr/bin/env \
      TART_XCUI_GUEST_USER="$login_user" \
      TART_XCUI_GUEST_PASSWORD="$login_password" \
      /bin/zsh "$0" "$@"
  exit
fi

xcode_archive=$1
xcode_app=$2
xcode_version=$3
xcode_build=$4
shift 4

platforms=()
components=()
sdks=()
while (( $# )); do
  case $1 in
    --platform) platforms+=("$2"); shift 2 ;;
    --component) components+=("$2"); shift 2 ;;
    --sdk) sdks+=("$2"); shift 2 ;;
    *) print -u2 -- "error: unknown provisioning argument: $1"; exit 1 ;;
  esac
done

for installer in /Applications/Install\ macOS*.app(N); do
  /bin/rm -rf "$installer"
done
if [[ $xcode_app != Xcode.app && -d /Applications/Xcode.app ]]; then
  /bin/rm -rf /Applications/Xcode.app
fi
installed_xcode_version=$(
  DEVELOPER_DIR="/Applications/$xcode_app/Contents/Developer" \
    /usr/bin/xcodebuild -version 2>/dev/null |
    /usr/bin/awk '/^Xcode/{print $2}'
) || true
installed_xcode_build=$(
  DEVELOPER_DIR="/Applications/$xcode_app/Contents/Developer" \
    /usr/bin/xcodebuild -version 2>/dev/null |
    /usr/bin/awk '/Build version/{print $3}'
) || true
if [[ $installed_xcode_version != $xcode_version ||
      $installed_xcode_build != $xcode_build ]]; then
  /bin/rm -rf "/Applications/$xcode_app"
  /usr/bin/ditto -x -k "$cache/$xcode_archive" /Applications
fi
/usr/bin/xcode-select -s "/Applications/$xcode_app/Contents/Developer"
/usr/bin/xcodebuild -license accept
/usr/bin/xcodebuild -runFirstLaunch
/usr/sbin/DevToolsSecurity -enable
/bin/chmod +x "$references/automation-mode.expect"
/usr/bin/sudo -u "$login_user" "$references/automation-mode.expect" \
  "$login_user" "$login_password"

for component in "${components[@]}"; do
  /usr/bin/xcodebuild -downloadComponent "$component"
done
for platform in "${platforms[@]}"; do
  /usr/bin/xcodebuild -downloadPlatform "$platform"
done

agent_archive="$cache/tart-guest-agent-0.11.0.tar.gz"
if [[ -f $agent_archive ]]; then
  agent_tmp=$(/usr/bin/mktemp -d)
  /usr/bin/tar -xzf "$agent_archive" -C "$agent_tmp"
  /bin/mkdir -p /usr/local/bin
  /usr/bin/install -m 0755 "$agent_tmp/tart-guest-agent" \
    /usr/local/bin/tart-guest-agent
  /usr/bin/install -o root -g wheel -m 0644 \
    "$references/tart-guest-daemon.plist" \
    /Library/LaunchDaemons/org.openai.tart-guest-daemon.plist
  /usr/bin/install -o root -g wheel -m 0644 \
    "$references/tart-guest-agent.plist" \
    /Library/LaunchAgents/org.openai.tart-guest-agent.plist
  /bin/rm -rf "$agent_tmp"
  /bin/launchctl bootout system/org.openai.tart-guest-daemon 2>/dev/null || true
  /bin/launchctl bootstrap system \
    /Library/LaunchDaemons/org.openai.tart-guest-daemon.plist
  /bin/launchctl bootstrap "gui/$login_uid" \
    /Library/LaunchAgents/org.openai.tart-guest-agent.plist 2>/dev/null || true
fi

# ponytail: these kcpassword bytes encode exactly "admin" — auto-login
# breaks if TART_XCUI_GUEST_PASSWORD is overridden; generate the xor bytes
# from the password if that ever needs to vary.
print '00000000: 1ced 3f4a bcbc ba2c caca 4e82' |
  /usr/bin/xxd -r - /etc/kcpassword
/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow \
  autoLoginUser "$login_user"
/usr/bin/defaults write /Library/Preferences/com.apple.screensaver \
  loginWindowIdleTime 0
/usr/bin/sudo -u "$login_user" /usr/bin/defaults -currentHost write \
  com.apple.screensaver idleTime 0
/usr/sbin/systemsetup -setsleep Off >/dev/null
/usr/sbin/systemsetup -setdisplaysleep Off >/dev/null
/usr/sbin/systemsetup -setcomputersleep Off >/dev/null
/usr/sbin/systemsetup -settimezone GMT >/dev/null
/usr/sbin/sysadminctl -screenLock off -password "$login_password"
/bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist \
  2>/dev/null || true
/bin/launchctl enable system/com.openssh.sshd
/bin/launchctl kickstart -k system/com.openssh.sshd

test "$(/usr/bin/xcodebuild -version | /usr/bin/awk '/^Xcode/{print $2}')" = "$xcode_version"
test "$(/usr/bin/xcodebuild -version | /usr/bin/awk '/Build version/{print $3}')" = "$xcode_build"
test "$(/usr/bin/xcode-select -p)" = "/Applications/$xcode_app/Contents/Developer"
/usr/bin/xcodebuild -checkFirstLaunchStatus
/usr/bin/xcrun -f clang >/dev/null
/usr/bin/xcrun -f metal >/dev/null
for sdk in "${sdks[@]}"; do
  /usr/bin/xcodebuild -showsdks | /usr/bin/grep -Fq -- "-sdk $sdk"
done
for platform in "${platforms[@]}"; do
  /usr/bin/xcrun simctl list runtimes available | /usr/bin/grep -Fq "$platform"
done
