packer {
  required_plugins {
    tart = {
      version = "= 1.21.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "ipsw" {
  type = string
}

variable "vm_name" {
  type = string
}

variable "xcode_archive" {
  type = string
}

variable "xcode_app_name" {
  type = string
}

variable "guest_agent_archive" {
  type = string
}

variable "macos_build" {
  type = string
}

variable "macos_version" {
  type = string
}

variable "xcode_build" {
  type = string
}

variable "xcode_version" {
  type = string
}

variable "platforms" {
  type    = list(string)
  default = ["iOS"]
}

variable "components" {
  type    = list(string)
  default = ["MetalToolchain"]
}

variable "sdks" {
  type = list(string)
}

variable "cpu" {
  type = number
}

variable "memory_gb" {
  type = number
}

variable "disk_gb" {
  type = number
}

source "tart-cli" "macos-beta" {
  from_ipsw    = var.ipsw
  vm_name      = var.vm_name
  cpu_count    = var.cpu
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_gb
  ssh_username = "admin"
  ssh_password = "admin"
  ssh_timeout  = "10m"
  headless     = true

  # Based on Cirrus Labs' vanilla Tahoe template. Setup Assistant is the only
  # beta-fragile part; a failure leaves the existing golden base untouched.
  boot_command = [
    # Advance hello to Language, then click the unlabeled Continue arrow.
    # Normalized coordinates survive the framebuffer scaling used during boot.
    "<wait60s><spacebar><wait30s><click '@0.86,0.855'>",
    "<wait60s><click 'Select Your Country or Region'><wait5s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    # Transfer Your Data to This Mac
    "<wait10s><click 'Set up as new'><wait1s><click 'Continue'>",
    # Written and Spoken Languages
    "<wait10s><click 'Continue'>",
    # Accessibility
    "<wait10s><click 'Not Now'>",
    # Data & Privacy
    "<wait10s><click 'Continue'>",
    # Create a Mac Account. macOS 27's avatar row changes keyboard focus order.
    "<wait10s><click 'Create a Mac Account'>",
    "<click '@0.50,0.44'><wait1s><leftMetaOn>a<leftMetaOff>Managed via Tart",
    "<click '@0.50,0.49'><wait1s><leftMetaOn>a<leftMetaOff>admin",
    "<click '@0.43,0.58'><wait1s><leftMetaOn>a<leftMetaOff>admin",
    "<click '@0.68,0.58'><wait1s><leftMetaOn>a<leftMetaOff>admin",
    "<wait1s><click 'Continue'>",
    # macOS 27 beta's post-account flow differs from macOS 26. Drive it by
    # visible labels so a changed screen fails with a bounded OCR timeout.
    "<wait120s><click 'Other Sign-In Options'>",
    "<wait5s><click 'Sign In Later in Settings'>",
    "<wait5s><click 'Skip'>",
    "<wait10s><click 'Continue'>",
    "<wait5s><click 'Continue'>",
    "<wait5s><click \"Don't Use\">",
    "<wait5s><click 'Continue'>",
    "<wait5s><click 'Continue'>",
    "<wait5s><click 'Set Up Later'>",
    "<wait5s><click 'Set Up Later'>",
    "<wait5s><click 'Not Now'>",
    "<wait5s><click 'Continue'>",
    "<wait5s><click 'Only Download Automatically'>",
    "<wait5s><click 'Continue'>",
    "<wait10s><click 'Get Started'>",
    "<wait20s><leftAltOn><spacebar><leftAltOff>Terminal<wait10s><enter>",
    "<wait20s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    "<wait5s>sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist<enter>",
    "<wait5s>admin<enter>",
    "<wait5s>sudo launchctl enable system/com.openssh.sshd<enter>",
    "<wait5s>sudo launchctl kickstart -k system/com.openssh.sshd<enter>",
  ]

  # macOS 27 beta may keep the restored VM in Tart's staging directory for
  # several minutes after Virtualization.framework reports completion.
  create_grace_time  = "5m"
  recovery_partition = "keep"
}

build {
  sources = ["source.tart-cli.macos-beta"]

  provisioner "shell" {
    execute_command = "echo admin | sudo -S -E /bin/sh '{{ .Path }}'"
    inline = [
      "echo '00000000: 1ced 3f4a bcbc ba2c caca 4e82' | xxd -r - /etc/kcpassword",
      "defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser admin",
      "defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0",
      "sudo -u admin defaults -currentHost write com.apple.screensaver idleTime 0",
      "systemsetup -setsleep Off 2>/dev/null",
      "systemsetup -setdisplaysleep Off 2>/dev/null",
      "systemsetup -setcomputersleep Off 2>/dev/null",
      "systemsetup -settimezone GMT 2>/dev/null",
      "sysadminctl -screenLock off -password admin",
    ]
  }

  provisioner "file" {
    source      = var.xcode_archive
    destination = "/Users/admin/Xcode.zip"
  }

  provisioner "file" {
    source      = var.guest_agent_archive
    destination = "/Users/admin/tart-guest-agent.tar.gz"
  }

  provisioner "file" {
    source      = "${path.root}/tart-guest-daemon.plist"
    destination = "/Users/admin/tart-guest-daemon.plist"
  }

  provisioner "file" {
    source      = "${path.root}/tart-guest-agent.plist"
    destination = "/Users/admin/tart-guest-agent.plist"
  }

  provisioner "file" {
    source      = "${path.root}/automation-mode.expect"
    destination = "/Users/admin/automation-mode.expect"
  }

  provisioner "shell" {
    execute_command = "echo admin | sudo -S -E /bin/sh '{{ .Path }}'"
    inline = concat(
      [
        "ditto -x -k /Users/admin/Xcode.zip /Applications",
        "xcode-select -s '/Applications/${var.xcode_app_name}/Contents/Developer'",
        "xcodebuild -license accept",
        "xcodebuild -runFirstLaunch",
        "DevToolsSecurity -enable",
        "chmod +x /Users/admin/automation-mode.expect",
        "sudo -u admin /Users/admin/automation-mode.expect admin admin",
      ],
      [for component in var.components : "xcodebuild -downloadComponent ${component}"],
      [for platform in var.platforms : "xcodebuild -downloadPlatform ${platform}"],
      [
        "mkdir -p /Users/admin/tart-guest-agent-unpack",
        "tar -xzf /Users/admin/tart-guest-agent.tar.gz -C /Users/admin/tart-guest-agent-unpack",
        "mkdir -p /usr/local/bin",
        "install -m 0755 /Users/admin/tart-guest-agent-unpack/tart-guest-agent /usr/local/bin/tart-guest-agent",
        "install -o root -g wheel -m 0644 /Users/admin/tart-guest-daemon.plist /Library/LaunchDaemons/org.openai.tart-guest-daemon.plist",
        "install -o root -g wheel -m 0644 /Users/admin/tart-guest-agent.plist /Library/LaunchAgents/org.openai.tart-guest-agent.plist",
        "test \"$(sw_vers -buildVersion)\" = '${var.macos_build}'",
        "test \"$(sw_vers -productVersion)\" = '${var.macos_version}'",
        "test \"$(xcodebuild -version | awk '/Build version/{print $3}')\" = '${var.xcode_build}'",
        "test \"$(xcodebuild -version | awk '/^Xcode/{print $2}')\" = '${var.xcode_version}'",
        "test \"$(xcode-select -p)\" = '/Applications/${var.xcode_app_name}/Contents/Developer'",
        "xcodebuild -checkFirstLaunchStatus",
        "xcrun -f clang >/dev/null",
        "xcrun -f metal >/dev/null",
        "test \"$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser)\" = admin",
        "test \"$(sudo -u admin defaults -currentHost read com.apple.screensaver idleTime)\" = 0",
      ],
      [for sdk in var.sdks : "xcodebuild -showsdks | grep -Fq -- '-sdk ${sdk}'"],
      [for platform in var.platforms : "xcrun simctl list runtimes available | grep -Fq ${platform}"],
      [
        "rm -rf /Users/admin/Xcode.zip /Users/admin/tart-guest-agent.tar.gz /Users/admin/tart-guest-agent-unpack",
      ],
    )
  }
}
