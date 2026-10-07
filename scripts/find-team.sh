#!/bin/bash
# Prints the team of the only Apple Development certificate in the keychain.
# With none or several, it says what to do and fails.
set -eu

# The team id is the organizational unit of the certificate.
set -- $(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"$/\1/p' | sort -u |
  while read -r name; do
    security find-certificate -c "$name" -p | openssl x509 -noout -subject -nameopt multiline |
      awk -F' = ' '/organizationalUnitName/ {print $2}'
  done | sort -u)

case $# in
  1) echo "$1" ;;
  0) echo "No Apple Development certificate. In Xcode > Settings > Accounts, select your account," \
       "click Manage Certificates, and add an Apple Development certificate." >&2
     exit 1 ;;
  *) echo "More than one team can sign glasstap. Run make install TEAM=<one of these>:" >&2
     printf '  %s\n' "$@" >&2
     exit 1 ;;
esac
