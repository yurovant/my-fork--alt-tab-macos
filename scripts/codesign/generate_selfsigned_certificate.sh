#!/usr/bin/env bash

set -exu

certificateFile="$1"
certificatePassword="$2"

# certificate request (see https://apple.stackexchange.com/q/359997)
cat >$certificateFile.conf <<EOL
  [ req ]
  distinguished_name = req_name
  prompt = no
  [ req_name ]
  CN = Local Self-Signed
  [ extensions ]
  basicConstraints=critical,CA:false
  keyUsage=critical,digitalSignature
  extendedKeyUsage=critical,1.3.6.1.5.5.7.3.3
  1.2.840.113635.100.6.1.14=critical,DER:0500
EOL

# generate key
openssl genrsa -out $certificateFile.key 2048
# generate self-signed certificate
# fork: 10 years; openssl's default is 30 days, after which local builds fail at CodeSign ("no identity found")
openssl req -x509 -new -days 3650 -config $certificateFile.conf -nodes -key $certificateFile.key -extensions extensions -sha256 -out $certificateFile.crt

openssl_version=$(openssl version)
# openssl v3+ requires to pass -legacy: its default PKCS12 encryption (AES-256 + SHA-256 MAC) fails `security import`
# see https://www.misterpki.com/openssl-pkcs12-legacy/
# fork: was `OpenSSL 3*` only, so OpenSSL 4 silently produced a .p12 that macOS can't import
if [[ $openssl_version == OpenSSL\ [3-9]* ]]; then
  flag="-legacy"
else
  flag=""
fi
# wrap key and certificate into PKCS12
openssl pkcs12 $flag -export -inkey $certificateFile.key -in $certificateFile.crt -out $certificateFile.p12 -passout pass:$certificatePassword
