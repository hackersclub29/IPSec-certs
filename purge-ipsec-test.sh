#!/bin/bash
# purge-ipsec-test.sh: remove the IPsec transport-mode test from this Linux machine.
#
# Usage:  sudo ./purge-ipsec-test.sh [-y] [--purge-packages]
#   -y                skip the confirmation prompt
#   --purge-packages  also uninstall the strongSwan packages
#   CERT_DIR=/path    folder where you ran "step certificate create"
#                     (default: $HOME/certs). Run as: sudo CERT_DIR=/path ./purge-ipsec-test.sh
set -u

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

ASSUME_YES=0
PURGE_PKGS=0
for arg in "$@"; do
    case "$arg" in
        -y) ASSUME_YES=1 ;;
        --purge-packages) PURGE_PKGS=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

CERT_DIR="${CERT_DIR:-$HOME/certs}"
SW=/etc/swanctl

# Files created by this test inside /etc/swanctl
SW_FILES=(
    "$SW/conf.d/test.conf"
    "$SW/conf.d/test.conf.off"
    "$SW/x509ca/root_ca.crt"
    "$SW/x509ca/intermediate_ca.crt"
    "$SW/x509/kali.crt"
    "$SW/private/kali.key"
)

# Files recorded by setup-ipsec-linux.sh (certificates, keys, connection configs)
MANIFEST=/var/lib/ipsec-test.manifest
if [ -f "$MANIFEST" ]; then
    while read -r p; do
        [ -n "$p" ] && SW_FILES+=("$p")
    done < "$MANIFEST"
fi

# Files created by "step certificate create" in the working folder
CERT_FILES=(
    root_ca.crt root_ca.key
    intermediate_ca.crt intermediate_ca.key
    kali.crt kali.key
    win.crt win.key win.pfx
)

echo "This will:"
echo "  - terminate the tunnel, stop and disable strongSwan, flush IPsec state and policies"
printf '  - delete %s\n' "${SW_FILES[@]}"
echo "  - delete the test certificates and keys (including root_ca.key) in $CERT_DIR"
[ "$PURGE_PKGS" -eq 1 ] && echo "  - uninstall the strongSwan packages"
echo "Other files in $SW (for example LANSeal configs) are not touched."
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
fi

wipe() {
    if [ -f "$1" ]; then
        shred -u "$1" 2>/dev/null || rm -f "$1"
        echo "removed $1"
    fi
}

# 1. Bring the tunnel down and stop the service
echo "== Stopping strongSwan"
swanctl --terminate --ike win-test >/dev/null 2>&1
systemctl stop strongswan 2>/dev/null
systemctl disable strongswan 2>/dev/null

# 2. Remove IPsec state and policies left in the kernel
echo "== Flushing IPsec state and policies"
ip xfrm state flush
ip xfrm policy flush

# 3. Remove the config and certificates from /etc/swanctl
echo "== Removing config and certificates"
for f in "${SW_FILES[@]}"; do wipe "$f"; done

rm -f "$MANIFEST"

# 4. Remove the include line only if no other conf.d files remain
if [ -f "$SW/swanctl.conf" ] && ! ls "$SW"/conf.d/*.conf >/dev/null 2>&1; then
    sed -i '\|^[[:space:]]*include[[:space:]]\+conf\.d/\*\.conf|d' "$SW/swanctl.conf"
    echo "removed the conf.d include line from $SW/swanctl.conf"
fi

# 5. Remove the certificates you generated (known file names only)
if [ -d "$CERT_DIR" ]; then
    echo "== Removing generated certificates in $CERT_DIR"
    for f in "${CERT_FILES[@]}"; do wipe "$CERT_DIR/$f"; done
    rmdir "$CERT_DIR" 2>/dev/null && echo "removed empty folder $CERT_DIR"
fi

# 6. Optional: uninstall the packages
if [ "$PURGE_PKGS" -eq 1 ]; then
    echo "== Uninstalling strongSwan packages"
    apt-get purge -y charon-systemd strongswan-swanctl strongswan-starter 2>/dev/null
    apt-get autoremove -y
fi

# 7. Verify
echo
echo "== Result"
echo "strongswan service: $(systemctl is-active strongswan 2>/dev/null) / $(systemctl is-enabled strongswan 2>/dev/null)"
echo "xfrm policy lines:  $(ip xfrm policy | wc -l)  (0 means clean)"
ls "$SW"/conf.d "$SW"/x509 "$SW"/x509ca "$SW"/private 2>/dev/null
echo "Done. Plain traffic to the other machine is no longer touched by IPsec."
