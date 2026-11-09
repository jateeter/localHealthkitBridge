#!/usr/bin/env bash
# The install CA as an iOS configuration profile (localHealthkitBridge#52).
#
# The PE serves its HealthKit device routes on TLS 1.3 under a certificate from
# the install's own CA (RealityEngine_CI scripts/lib/re_pki.py). The iPhone
# verifies it against its trust store, so the CA has to be in it. This script
# writes the profile that puts it there. It changes no trust store: installing
# the profile is the owner's step (RealityEngine_CI docs/TRANSPORT_SECURITY.md).
#
# Usage:
#   scripts/ca_profile.sh [--ca PATH] [--out PATH]
#
#   --ca   the CA certificate (PEM). Default: $RE_TLS_CA, else
#          $RE_PKI_DIR/ca/ca.crt, else ~/.reality-engine/pki/${RE_PKI_LANE:-native}/ca/ca.crt
#   --out  where to write the profile. Default: ./RealityEngine-CA.mobileconfig
#
# Then, on the iPhone:
#   1. AirDrop the .mobileconfig to the phone (or open it from Files) and
#      install it: Settings > General > VPN & Device Management.
#   2. Turn on full trust for it: Settings > General > About >
#      Certificate Trust Settings. Without this step iOS installs the
#      certificate but does not trust it for TLS, and every https call to the PE
#      fails with a trust error.
#
# The profile's identifier is derived from the CA's fingerprint, so a profile for
# the same CA replaces itself and a profile for a new CA installs beside it.
set -euo pipefail

CA="${RE_TLS_CA:-${RE_PKI_DIR:-$HOME/.reality-engine/pki/${RE_PKI_LANE:-native}}/ca/ca.crt}"
OUT="RealityEngine-CA.mobileconfig"
while [ $# -gt 0 ]; do
  case "$1" in
    --ca) CA="$2"; shift 2 ;;
    --ca=*) CA="${1#*=}"; shift ;;
    --out) OUT="$2"; shift 2 ;;
    --out=*) OUT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -r "$CA" ] || { echo "no CA certificate at $CA (start a universe with RE_TLS=on, or pass --ca)" >&2; exit 1; }
openssl x509 -in "$CA" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE' \
  || { echo "$CA is not a CA certificate" >&2; exit 1; }

subject="$(openssl x509 -in "$CA" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')"
fingerprint="$(openssl x509 -in "$CA" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"
der_b64="$(openssl x509 -in "$CA" -outform DER | base64 | tr -d '\n')"
# Stable UUIDs from the fingerprint, so re-running for the same CA yields the same profile.
uuid_from() { printf '%s' "$1" | shasum -a 256 | sed -E 's/^(.{8})(.{4}).(.{3}).(.{3})(.{12}).*/\1-\2-4\3-8\4-\5/' | tr 'a-f' 'A-F'; }
profile_uuid="$(uuid_from "profile-$fingerprint")"
payload_uuid="$(uuid_from "payload-$fingerprint")"
short="${fingerprint:0:16}"
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
subject_xml="$(printf '%s' "$subject" | xml_escape)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key><string>com.apple.security.root</string>
      <key>PayloadVersion</key><integer>1</integer>
      <key>PayloadIdentifier</key><string>org.energyos.realityengine.ca.${short}.cert</string>
      <key>PayloadUUID</key><string>${payload_uuid}</string>
      <key>PayloadDisplayName</key><string>${subject_xml}</string>
      <key>PayloadCertificateFileName</key><string>realityengine-ca-${short}.cer</string>
      <key>PayloadContent</key><data>${der_b64}</data>
    </dict>
  </array>
  <key>PayloadType</key><string>Configuration</string>
  <key>PayloadVersion</key><integer>1</integer>
  <key>PayloadIdentifier</key><string>org.energyos.realityengine.ca.${short}</string>
  <key>PayloadUUID</key><string>${profile_uuid}</string>
  <key>PayloadDisplayName</key><string>RealityEngine install CA</string>
  <key>PayloadDescription</key><string>Trusts the RealityEngine install CA (${subject_xml}, SHA-256 ${fingerprint}) so the HealthKit bridge can verify the Perception Engine over TLS 1.3. Enable full trust in Settings &gt; General &gt; About &gt; Certificate Trust Settings.</string>
  <key>PayloadOrganization</key><string>RealityEngine</string>
  <key>PayloadRemovalDisallowed</key><false/>
</dict>
</plist>
EOF
plutil -lint "$tmp" >/dev/null
mv "$tmp" "$OUT"
trap - EXIT
chmod 644 "$OUT"
echo "$OUT"
echo "CA:  $subject"
echo "SHA-256: $fingerprint"
echo "Install it on the iPhone, then enable full trust (Settings > General > About > Certificate Trust Settings)."
