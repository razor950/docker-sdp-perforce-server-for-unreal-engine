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

# Source P4 environment
source /p4/common/bin/p4_vars "${SDP_INSTANCE}" || bail "Failed to source P4 environment"

# SSL directory - CRITICAL: This must be exactly P4SSLDIR value
SSL_DIR="${P4SSLDIR:-/p4/ssl}"
msg "Using SSL directory: $SSL_DIR"

# Ensure SSL directory exists with correct ownership and permissions
sudo mkdir -p "$SSL_DIR"
sudo chown perforce:perforce "$SSL_DIR"
sudo chmod 700 "$SSL_DIR"  # CRITICAL: P4SSLDIR must be 700

msg "SSL directory permissions set: $(ls -ld "$SSL_DIR")"

# Check if custom certificates exist
CUSTOM_CERT="${SSL_DIR}/certificate.txt"
CUSTOM_KEY="${SSL_DIR}/privatekey.txt"
SSL_CONFIG="${SSL_DIR}/config.txt"

if [[ -f "$CUSTOM_CERT" && -f "$CUSTOM_KEY" ]]; then
    msg "Found custom SSL certificates, setting correct permissions..."
    
    # Verify certificate files are readable
    if [[ ! -r "$CUSTOM_CERT" ]] || [[ ! -r "$CUSTOM_KEY" ]]; then
        bail "SSL certificate files exist but are not readable. Check file permissions."
    fi
    
    # Set CRITICAL permissions for existing certificates
    sudo chown perforce:perforce "$CUSTOM_CERT" "$CUSTOM_KEY"
    sudo chmod 600 "$CUSTOM_KEY"      # Private key must be 600
    sudo chmod 644 "$CUSTOM_CERT"     # Certificate can be 644
    
    if [[ -f "$SSL_CONFIG" ]]; then
        sudo chown perforce:perforce "$SSL_CONFIG"
        sudo chmod 644 "$SSL_CONFIG"
        msg "  Config file: $SSL_CONFIG"
    fi
    
    msg "✅ Using custom SSL certificates with correct permissions"
    
else
    msg "No custom SSL certificates found. Generating self-signed certificate..."
    
    # Create SSL config file for self-signed certificate
    sudo -u perforce cat > "$SSL_CONFIG" << EOF
# SSL Certificate Configuration for Perforce
C  = US
ST = FL
L  = Miami
O  = Perforce Autogen Cert
OU = IT Department
CN = ${P4_MASTER_HOST:-localhost}

# EX: number of days from today for certificate expiration
# (default: 730, e.g. 2 years)
EX = 3650

# UNITS: unit multiplier for expiration (defaults to "days")
# Valid values: "secs", "mins", "hours"
UNITS = days
EOF
    # Set correct ownership and permissions for config
    sudo chown perforce:perforce "$SSL_CONFIG"
    sudo chmod 644 "$SSL_CONFIG"
    
    msg "Created SSL config file: $SSL_CONFIG"
    
    # Check if server is running and stop it if necessary
    SERVER_WAS_RUNNING=0
    if sudo -u perforce /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status >/dev/null 2>&1; then
        msg "Stopping Perforce server to generate SSL certificate..."
        sudo -u perforce /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop
        SERVER_WAS_RUNNING=1
        sleep 2
    fi
    
    # Generate certificate using p4d's built-in SSL certificate generation
    # CRITICAL: Must run as perforce user and in SSL directory
    cd "$SSL_DIR" || bail "Could not cd to SSL directory"
    
    # Use the p4d binary to generate certificates
    P4D_BIN="/p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}"
    if [[ ! -f "$P4D_BIN" ]]; then
        # Fallback to common bin location
        P4D_BIN="/p4/common/bin/p4d_${SDP_INSTANCE}_bin"
    fi
    
    if [[ ! -f "$P4D_BIN" ]]; then
        bail "Cannot find p4d binary for SSL certificate generation"
    fi
    
    msg "Using p4d binary: $P4D_BIN"
    msg "Generating SSL certificate as perforce user..."
    
    # CRITICAL: Generate certificate as perforce user with proper environment
    if sudo -u perforce -i bash << CERT_GEN_SCRIPT
set -e
export P4SSLDIR="$SSL_DIR"
export P4ROOT="$P4ROOT"
cd "$SSL_DIR"
"$P4D_BIN" -r "$P4ROOT" -Gc
CERT_GEN_SCRIPT
    then
        msg "✅ Self-signed SSL certificate generated successfully"
        
        # Verify and set proper permissions on generated files
        for ssl_file in certificate.txt privatekey.txt; do
            if [[ -f "$SSL_DIR/$ssl_file" ]]; then
                sudo chown perforce:perforce "$SSL_DIR/$ssl_file"
                if [[ "$ssl_file" == "privatekey.txt" ]]; then
                    sudo chmod 600 "$SSL_DIR/$ssl_file"  # Private key must be 600
                else
                    sudo chmod 644 "$SSL_DIR/$ssl_file"  # Certificate can be 644
                fi
                msg "Set permissions on $ssl_file: $(ls -l "$SSL_DIR/$ssl_file")"
            else
                errmsg "Expected SSL file not found: $SSL_DIR/$ssl_file"
            fi
        done
        
        # Display certificate info
        if [[ -f "$SSL_DIR/certificate.txt" ]]; then
            msg "Certificate information:"
            sudo -u perforce openssl x509 -in "$SSL_DIR/certificate.txt" -text -noout | grep -E "(Subject:|Not Before|Not After|DNS:|IP Address:)" 2>/dev/null || true
        fi
        
    else
        bail "Failed to generate SSL certificate with p4d -Gc"
    fi
    
    # Restart server if it was running
    if [[ $SERVER_WAS_RUNNING -eq 1 ]]; then
        msg "Starting Perforce server..."
        sudo -u perforce /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start
        sleep 3
    fi
fi

# Final verification of SSL setup
msg "Performing final SSL verification..."

# Verify all required SSL files exist with correct permissions
SSL_FILES_OK=1
REQUIRED_FILES=("certificate.txt" "privatekey.txt")

for ssl_file in "${REQUIRED_FILES[@]}"; do
    file_path="$SSL_DIR/$ssl_file"
    if [[ ! -f "$file_path" ]]; then
        errmsg "Missing SSL file: $file_path"
        SSL_FILES_OK=0
    else
        # Check ownership
        file_owner=$(stat -c '%U:%G' "$file_path" 2>/dev/null || echo "unknown:unknown")
        if [[ "$file_owner" != "perforce:perforce" ]]; then
            errmsg "Wrong ownership on $file_path: $file_owner (should be perforce:perforce)"
            SSL_FILES_OK=0
        fi
        
        # Check permissions
        file_perms=$(stat -c '%a' "$file_path" 2>/dev/null || echo "000")
        if [[ "$ssl_file" == "privatekey.txt" && "$file_perms" != "600" ]]; then
            errmsg "Wrong permissions on $file_path: $file_perms (should be 600)"
            SSL_FILES_OK=0
        elif [[ "$ssl_file" == "certificate.txt" && "$file_perms" != "644" ]]; then
            warnmsg "Unusual permissions on $file_path: $file_perms (expected 644, but this may be OK)"
        fi
    fi
done

# Check SSL directory permissions
ssl_dir_perms=$(stat -c '%a' "$SSL_DIR" 2>/dev/null || echo "000")
ssl_dir_owner=$(stat -c '%U:%G' "$SSL_DIR" 2>/dev/null || echo "unknown:unknown")

if [[ "$ssl_dir_perms" != "700" ]]; then
    errmsg "Wrong permissions on SSL directory $SSL_DIR: $ssl_dir_perms (should be 700)"
    SSL_FILES_OK=0
fi

if [[ "$ssl_dir_owner" != "perforce:perforce" ]]; then
    errmsg "Wrong ownership on SSL directory $SSL_DIR: $ssl_dir_owner (should be perforce:perforce)"
    SSL_FILES_OK=0
fi

if [[ $SSL_FILES_OK -eq 1 ]]; then
    msg "✅ SSL files and permissions verified:"
    ls -la "$SSL_DIR"
    
    # Show SSL fingerprint for client trust
    if [[ -f "$SSL_DIR/certificate.txt" ]]; then
        FINGERPRINT=$(sudo -u perforce openssl x509 -in "$SSL_DIR/certificate.txt" -fingerprint -sha256 -noout 2>/dev/null | cut -d'=' -f2)
        if [[ -n "$FINGERPRINT" ]]; then
            msg ""
            msg "🔐 SSL Certificate Fingerprint (SHA256):"
            msg "   $FINGERPRINT"
            msg ""
            msg "📋 Clients will need to trust this certificate (first connect):"
            msg "   p4 trust -y"
        fi
    fi
    
    msg "✅ SSL setup completed successfully"
    msg ""
    msg "🔒 SSL is now enabled for Perforce server"
    msg "   Server URL: ssl:${P4_MASTER_HOST:-localhost}:${P4PORT##*:}"
    msg "   P4SSLDIR: $SSL_DIR"
    msg "   Clients must use 'ssl:' prefix in P4PORT"
else
    bail "❌ SSL setup failed - certificate files or permissions are incorrect"
fi

exit $ErrorCount