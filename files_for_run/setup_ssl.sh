#!/bin/bash
set -eu

#------------------------------------------------------------------------------
# Perforce SSL Setup Script
# 
# This script sets up SSL certificates for Perforce server.
# It can either generate self-signed certificates or use provided ones.
#------------------------------------------------------------------------------

# Functions for logging
function msg () { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }
function errmsg () { msg "ERROR: ${1:-Unknown Error}"; ErrorCount+=1; }
function warnmsg () { msg "WARNING: ${1:-Unknown Warning}"; WarningCount+=1; }
function bail () { errmsg "${1:-Unknown Error}"; exit "${2:-1}"; }

# Initialize counters
declare -i ErrorCount=0
declare -i WarningCount=0

SDP_INSTANCE=${SDP_INSTANCE:-1}
P4_SSL_PREFIX=${P4_SSL_PREFIX:-}

# Check if SSL is enabled
if [[ "$P4_SSL_PREFIX" != "ssl:" ]]; then
    msg "SSL not enabled (P4_SSL_PREFIX is not 'ssl:'). Skipping SSL setup."
    exit 0
fi

msg "Setting up SSL for Perforce instance ${SDP_INSTANCE}"

# Source P4 environment
source /p4/common/bin/p4_vars "${SDP_INSTANCE}" || bail "Failed to source P4 environment"

# SSL directory
SSL_DIR="/p4/ssl"
mkdir -p "$SSL_DIR"

# Check if custom certificates exist
CUSTOM_CERT="${SSL_DIR}/certificate.txt"
CUSTOM_KEY="${SSL_DIR}/privatekey.txt"
SSL_CONFIG="${SSL_DIR}/config.txt"

if [[ -f "$CUSTOM_CERT" && -f "$CUSTOM_KEY" ]]; then
    msg "Found custom SSL certificates:"
    msg "  Certificate: $CUSTOM_CERT"
    msg "  Private Key: $CUSTOM_KEY"
    
    # Verify certificate files are readable
    if [[ ! -r "$CUSTOM_CERT" ]] || [[ ! -r "$CUSTOM_KEY" ]]; then
        bail "SSL certificate files exist but are not readable. Check file permissions."
    fi
    
    # Set proper ownership
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
    
    # Create SSL config file for self-signed certificate
    cat > "$SSL_CONFIG" << EOF
# SSL Certificate Configuration for Perforce
# This file is used when generating self-signed certificates

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
CN=${P4_MASTER_HOST}
emailAddress=admin@${P4_DOMAIN}

[ v3_req ]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${P4_MASTER_HOST}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

    # Set ownership of config file
    chown perforce:perforce "$SSL_CONFIG"
    chmod 644 "$SSL_CONFIG"
    
    msg "Created SSL config file: $SSL_CONFIG"
    
    # Generate self-signed certificate using p4d
    msg "Generating self-signed certificate with p4d..."
    
    # Check if server is running
    SERVER_WAS_RUNNING=0
    if /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status >/dev/null 2>&1; then
        msg "Stopping Perforce server to generate SSL certificate..."
        /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop
        SERVER_WAS_RUNNING=1
    fi
    
    # Generate certificate using p4d's built-in SSL certificate generation
    cd "$SSL_DIR" || bail "Could not cd to SSL directory"
    
    # Use the p4d binary directly to generate certificates
    P4D_BIN="/p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}"
    if [[ ! -f "$P4D_BIN" ]]; then
        # Fallback to common bin location
        P4D_BIN="/p4/common/bin/p4d"
    fi
    
    if [[ ! -f "$P4D_BIN" ]]; then
        bail "Cannot find p4d binary for SSL certificate generation"
    fi
    
    msg "Using p4d binary: $P4D_BIN"
    
    if sudo -u perforce "$P4D_BIN" -r "$P4ROOT" -Gc; then
        msg "✅ Self-signed SSL certificate generated successfully"
        
        # Set proper permissions
        chown perforce:perforce "$SSL_DIR"/* 2>/dev/null || true
        chmod 600 "$SSL_DIR/privatekey.txt" 2>/dev/null || true
        chmod 644 "$SSL_DIR/certificate.txt" 2>/dev/null || true
        
        # Display certificate info
        if [[ -f "$SSL_DIR/certificate.txt" ]]; then
            msg "Certificate information:"
            openssl x509 -in "$SSL_DIR/certificate.txt" -text -noout | grep -E "(Subject:|Not Before|Not After|DNS:|IP Address:)" 2>/dev/null || true
        fi
        
    else
        bail "Failed to generate SSL certificate with p4d -Gc"
    fi
    
    # Restart server if it was running
    if [[ $SERVER_WAS_RUNNING -eq 1 ]]; then
        msg "Starting Perforce server..."
        /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start
    fi
fi

# Verify SSL setup
msg "Verifying SSL setup..."

SSL_FILES_EXIST=1
for ssl_file in "certificate.txt" "privatekey.txt"; do
    if [[ ! -f "$SSL_DIR/$ssl_file" ]]; then
        errmsg "Missing SSL file: $SSL_DIR/$ssl_file"
        SSL_FILES_EXIST=0
    fi
done

if [[ $SSL_FILES_EXIST -eq 1 ]]; then
    msg "✅ SSL files present:"
    ls -la "$SSL_DIR"
    
    # Show SSL fingerprint for client trust
    if [[ -f "$SSL_DIR/certificate.txt" ]]; then
        FINGERPRINT=$(openssl x509 -in "$SSL_DIR/certificate.txt" -fingerprint -sha256 -noout 2>/dev/null | cut -d'=' -f2)
        if [[ -n "$FINGERPRINT" ]]; then
            msg ""
            msg "🔐 SSL Certificate Fingerprint (SHA256):"
            msg "   $FINGERPRINT"
            msg ""
            msg "📋 Clients will need to trust this certificate."
            msg "   Use 'p4 trust -y' on first connection."
        fi
    fi
fi

if [[ $ErrorCount -gt 0 ]]; then
    bail "SSL setup completed with ${ErrorCount} errors"
else
    msg "✅ SSL setup completed successfully"
    
    if [[ "$P4_SSL_PREFIX" == "ssl:" ]]; then
        msg ""
        msg "🔒 SSL is now enabled for Perforce server"
        msg "   Server URL: ssl:${P4_MASTER_HOST}:${P4_PORT#*:}"
        msg "   Clients must use 'ssl:' prefix in P4PORT"
    fi
fi