#!/bin/bash
set -eu

#------------------------------------------------------------------------------
# Perforce SSL Setup Script
#------------------------------------------------------------------------------

msg()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
errmsg()  { msg "ERROR: ${1:-Unknown Error}"; ErrorCount+=1; }
warnmsg() { msg "WARNING: ${1:-Unknown Warning}"; WarningCount+=1; }
bail()    { errmsg "${1:-Unknown Error}"; exit "${2:-1}"; }

declare -i ErrorCount=0
declare -i WarningCount=0

SDP_INSTANCE=${SDP_INSTANCE:-1}
P4_SSL_PREFIX=${P4_SSL_PREFIX:-}

# Exit early if SSL isn't intended
if [[ "$P4_SSL_PREFIX" != "ssl:" ]]; then
  msg "SSL not enabled (P4_SSL_PREFIX != 'ssl:'). Skipping SSL setup."
  exit 0
fi

msg "Setting up SSL for Perforce instance ${SDP_INSTANCE}"

# Load SDP env (defines P4ROOT, P4PORT, P4SSLDIR, etc.)
source /p4/common/bin/p4_vars "${SDP_INSTANCE}" || bail "Failed to source P4 env"

# Use the official SSL dir from env, not a hard-coded path
SSL_DIR="${P4SSLDIR:-/p4/ssl}"
umask 077; install -d -m 700 -o perforce -g perforce "$SSL_DIR"

# Ensure secure ownership/perms on the directory BEFORE anything else
#chown -R perforce:perforce "$SSL_DIR" || true
#chmod 700 "$SSL_DIR" || true

CUSTOM_CERT="${SSL_DIR}/certificate.txt"
CUSTOM_KEY="${SSL_DIR}/privatekey.txt"
SSL_CONFIG="${SSL_DIR}/config.txt"

if [[ -f "$CUSTOM_CERT" && -f "$CUSTOM_KEY" ]]; then
  msg "Found custom SSL certificates:"
  msg "  Certificate: $CUSTOM_CERT"
  msg "  Private Key: $CUSTOM_KEY"

  # Verify readability (and set secure perms/ownership)
  if [[ ! -r "$CUSTOM_CERT" || ! -r "$CUSTOM_KEY" ]]; then
    bail "SSL certificate files exist but are not readable. Check file permissions."
  fi

  chown perforce:perforce "$CUSTOM_CERT" "$CUSTOM_KEY"
  chmod 600 "$CUSTOM_KEY"
  chmod 644 "$CUSTOM_CERT"

  if [[ -f "$SSL_CONFIG" ]]; then
    chown perforce:perforce "$SSL_CONFIG"
    chmod 644 "$SSL_CONFIG"
    msg "  Config file: $SSL_CONFIG"
  fi

  msg "✅ Using custom SSL certificates"

else
  msg "No custom SSL certificates found. Generating self-signed certificate..."

  cat > "$SSL_CONFIG" <<EOF
# SSL Certificate Configuration for Perforce
[ req ]
default_bits = 2048
prompt = no
distinguished_name = req_distinguished_name
req_extensions = v3_req

[ req_distinguished_name ]
C=US
ST=State
L=City
O=Organization
OU=IT Department
CN=${P4_MASTER_HOST:-localhost}
emailAddress=admin@${P4_DOMAIN:-example.com}

[ v3_req ]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${P4_MASTER_HOST:-localhost}
DNS.2 = localhost
IP.1  = 127.0.0.1
EOF

  chown perforce:perforce "$SSL_CONFIG"
  chmod 644 "$SSL_CONFIG"

  msg "Created SSL config file: $SSL_CONFIG"

  # Stop server if running (safe no-op if not)
  SERVER_WAS_RUNNING=0
  if /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status >/dev/null 2>&1; then
    msg "Stopping Perforce server to generate SSL certificate..."
    /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop || true
    SERVER_WAS_RUNNING=1
  fi

  cd "$SSL_DIR" || bail "Could not cd to SSL directory"

  # Locate p4d binary
  P4D_BIN="/p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}"
  [[ -f "$P4D_BIN" ]] || P4D_BIN="/p4/common/bin/p4d"
  [[ -f "$P4D_BIN" ]] || bail "Cannot find p4d binary for SSL certificate generation"

  msg "Using p4d binary: $P4D_BIN"

  # Prefer running as the perforce user; fall back if sudo is missing
  if command -v sudo >/dev/null 2>&1; then
    sudo -u perforce "$P4D_BIN" -r "$P4ROOT" -Gc
  else
    su -s /bin/bash - perforce -c "\"$P4D_BIN\" -r \"$P4ROOT\" -Gc"
  fi

  msg "✅ Self-signed SSL certificate generated successfully"

  # Secure perms again (p4d -Gc usually does this, but be explicit)
  chown perforce:perforce "$SSL_DIR"/{certificate.txt,privatekey.txt} 2>/dev/null || true
  chmod 600 "$SSL_DIR/privatekey.txt" 2>/dev/null || true
  chmod 644 "$SSL_DIR/certificate.txt" 2>/dev/null || true
  chmod 700 "$SSL_DIR" || true

  # Display cert info (optional)
  if command -v openssl >/dev/null 2>&1 && [[ -f "$SSL_DIR/certificate.txt" ]]; then
    msg "Certificate information:"
    openssl x509 -in "$SSL_DIR/certificate.txt" -text -noout | grep -E "(Subject:|Not Before|Not After|DNS:|IP Address:)" || true
  fi

  # Restart server if it was running
  if [[ $SERVER_WAS_RUNNING -eq 1 ]]; then
    msg "Starting Perforce server..."
    /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start || true
  fi
fi

# Verify SSL setup
msg "Verifying SSL setup..."

SSL_FILES_EXIST=1
for f in certificate.txt privatekey.txt; do
  if [[ ! -f "$SSL_DIR/$f" ]]; then
    errmsg "Missing SSL file: $SSL_DIR/$f"
    SSL_FILES_EXIST=0
  fi
done

if [[ $SSL_FILES_EXIST -eq 1 ]]; then
  msg "✅ SSL files present:"
  ls -la "$SSL_DIR" || true

  if command -v openssl >/dev/null 2>&1 && [[ -f "$SSL_DIR/certificate.txt" ]]; then
    FINGERPRINT=$(openssl x509 -in "$SSL_DIR/certificate.txt" -fingerprint -sha256 -noout 2>/dev/null | cut -d'=' -f2 || true)
    if [[ -n "${FINGERPRINT:-}" ]]; then
      msg ""
      msg "🔐 SSL Certificate Fingerprint (SHA256):"
      msg "   $FINGERPRINT"
      msg ""
      msg "📋 Clients will need to trust this certificate (first connect):"
      msg "   p4 trust -y"
    fi
  fi
fi

if [[ $ErrorCount -gt 0 ]]; then
  bail "SSL setup completed with ${ErrorCount} errors"
else
  msg "✅ SSL setup completed successfully"
  if [[ "${P4_SSL_PREFIX}" == "ssl:" ]]; then
    # Use P4PORT (not P4_PORT) and avoid unbound-var explosions
    msg ""
    msg "🔒 SSL is now enabled for Perforce server"
    msg "   Server URL: ${P4PORT:-ssl:localhost:1666}"
    msg "   Clients must use 'ssl:' prefix in P4PORT"
  fi
fi
