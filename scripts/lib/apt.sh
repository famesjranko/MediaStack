# Owns: MS_APT_INSTALL / MS_APT_REMOVE / MS_APT_PURGE - the non-interactive apt-get prefixes.
# Sourced by every setup module that installs packages; sets no shell options.

# Without DEBIAN_FRONTEND=noninteractive, packages pulled in as dependencies on
# cloud images (keyboard-configuration, console-setup) open a debconf dialog on
# the TTY behind ui_spin, so the install looks hung. `sudo env` sets it even
# when sudoers env_reset would drop a `sudo VAR=value` assignment; conffile
# defaults keep dpkg from prompting about modified config files.
# Use: "${MS_APT_INSTALL[@]}" pkg... (tests/unit/apt-noninteractive.sh enforces it).
# shellcheck disable=SC2034 # read by the modules that source this file
MS_APT_INSTALL=(sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Same environment for removals: a purge can prompt too (debconf, dpkg conffiles).
# shellcheck disable=SC2034 # read by the modules that source this file
MS_APT_REMOVE=(sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq)
# shellcheck disable=SC2034 # read by the modules that source this file
MS_APT_PURGE=(sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq)
