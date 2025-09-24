#!/bin/bash
set -u

#------------------------------------------------------------------------------
# Functions msg(), dbg(), and bail().
# Sample Usage:
#    bail "Missing something important. Aborting."
#    bail "Aborting with exit code 3." 3
function msg () { echo -e "$*"; }
function warnmsg () { msg "\\nWarning: ${1:-Unknown Warning}\\n"; WarningCount+=1; }
function errmsg () { msg "\\nError: ${1:-Unknown Error}\\n"; ErrorCount+=1; }
function dbg () { msg "DEBUG: $*" >&2; }
function bail () { errmsg "${1:-Unknown Error}"; exit "${2:-1}"; }

#------------------------------------------------------------------------------
# Functions run($cmd, $desc)
#
# This function is similar to functions defined in SDP core libraries, but we
# need to duplicate them here since this script runs before the SDP is
# available on the machine (and we require dependencies for this
# script).
function run {
   cmd="${1:-echo Testing run}"
   desc="${2:-}"
   [[ -n "$desc" ]] && msg "$desc"
   msg "Running: $cmd"
   $cmd
   CMDEXITCODE=$?
   return $CMDEXITCODE
}

# Part of this script follows the instructions:
# https://swarm.workshop.perforce.com/projects/perforce-software-sdp/view/main/doc/SDP_Guide.Unix.html#_manual_install

HxDepots=/hxdepots

# 11. Set environment variable SDP.
export SDP=${HxDepots}/sdp

# Check if SDP has installed.
SDPVersionFile=${SDP}/Version
msg "Check ${SDPVersionFile} existance."

if [ ! -e ${SDPVersionFile} ]; then
   msg "Installing SDP"

   # 10. Extract the SDP tarball.
   DownloadsDir=/usr/local/bin
   cd ${HxDepots}
   run "tar -xzpf ${DownloadsDir}/sdp.Unix.tgz" "Unpacking ${DownloadsDir}/sdp.Unix.tgz in ${PWD}." ||\
      bail "Failed to untar SDP tarfile."

   # 12. Make the entire $SDP (/hxdepots/sdp) directory writable by perforce:perforce with this command:
   chmod -R +w ${SDP}

   # 13. Copy every existing p4 binaries into SDP folder.
   if [ -d "${DownloadsDir}/helix_binaries/" ]; then
      run "cp ${DownloadsDir}/helix_binaries/* ${SDP}/helix_binaries/"
   fi
else
   msg "SDP already installed, version:"
   cat ${SDPVersionFile}
fi

robust_p4d_stop() {
    local instance=${1:-1}
    local timeout=${2:-15}
    
    msg "Attempting to stop p4d instance $instance (timeout: ${timeout}s)..."
    
    # Method 1: Try the official init script first
    if /p4/${instance}/bin/p4d_${instance}_init stop; then
        msg "Init script stop command executed"
    else
        warnmsg "Init script stop returned non-zero exit code"
    fi
    
    # Method 2: Find and kill p4d processes directly
    local pids=""
    local attempts=0
    while [[ $attempts -lt $timeout ]]; do
        # Find p4d processes for this instance
        pids=$(pgrep -f "p4d_${instance}.*--daemonsafe" 2>/dev/null || true)
        
        if [[ -z "$pids" ]]; then
            msg "✅ p4d instance $instance stopped successfully"
            return 0
        fi
        
        msg "Found p4d processes: $pids (attempt $((attempts+1))/$timeout)"
        
        if [[ $attempts -eq 0 ]]; then
            # First attempt: SIGTERM (graceful)
            echo "$pids" | xargs -r kill -TERM 2>/dev/null || true
            msg "Sent SIGTERM to p4d processes"
        elif [[ $attempts -eq $((timeout-5)) ]]; then
            # Near timeout: SIGKILL (forceful) 
            echo "$pids" | xargs -r kill -KILL 2>/dev/null || true
            msg "Sent SIGKILL to p4d processes"
        fi
        
        sleep 1
        attempts=$((attempts+1))
    done
    
    # Final check after timeout
    pids=$(pgrep -f "p4d_${instance}.*--daemonsafe" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        errmsg "❌ Failed to stop p4d processes after ${timeout}s: $pids"
        
        # Last resort: nuclear option
        msg "Attempting final SIGKILL..."
        echo "$pids" | xargs -r kill -9 2>/dev/null || true
        sleep 2
        
        # Check if it worked
        pids=$(pgrep -f "p4d_${instance}.*--daemonsafe" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            errmsg "❌ CRITICAL: Cannot stop p4d processes: $pids"
            return 1
        else
            msg "✅ p4d stopped with SIGKILL"
        fi
    else
        msg "✅ p4d instance $instance stopped successfully"
    fi
    
    # Method 3: Clean up any leftover pid files
    local pidfiles=(
        "/p4/${instance}/tmp/p4d.pid"
        "/p4/${instance}/logs/p4d.pid" 
        "/p4/${instance}/p4d.pid"
    )
    
    for pidfile in "${pidfiles[@]}"; do
        if [[ -f "$pidfile" ]]; then
            msg "Removing stale pid file: $pidfile"
            rm -f "$pidfile" || true
        fi
    done
    
    # Method 4: Check if port is still in use
    if command -v ss >/dev/null 2>&1; then
        local port_check=$(ss -tlnp | grep ":1666 " || true)
    elif command -v netstat >/dev/null 2>&1; then
        local port_check=$(netstat -tlnp | grep ":1666 " || true)
    else
        local port_check=""
    fi
    
    if [[ -n "$port_check" ]]; then
        warnmsg "Port 1666 still appears to be in use: $port_check"
        # Extract PID from netstat/ss output and kill it
        local port_pid=$(echo "$port_check" | grep -o '[0-9]\+/p4d' | cut -d'/' -f1 | head -1)
        if [[ -n "$port_pid" ]]; then
            msg "Killing process holding port 1666: PID $port_pid"
            kill -9 "$port_pid" 2>/dev/null || true
        fi
    fi
    
    return 0
}

# Check if the P4 Instance has configured.
P4DInstanceScript=/p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}
msg "Check ${P4DInstanceScript} existance."

if [ ! -e ${P4DInstanceScript} ]; then
   # Configure for new instance
   # This part references from:
   # https://swarm.workshop.perforce.com/projects/perforce_software-helix-installer/files/main/src/reset_sdp.sh

   msg "Configuring new SDP instance: ${SDP_INSTANCE}"
   declare SDPSetupDir="${SDP}/Server/Unix/setup"
   cd "${SDPSetupDir}" || bail "Could not cd to [${SDPSetupDir}]."
   
   # 1. Call mkdirs.sh first.
   CfgDir=/usr/local/bin
   MkdirsCfgPath=${CfgDir}/mkdirs.unreal.cfg
   cp -p ${MkdirsCfgPath} mkdirs.${SDP_INSTANCE}.cfg

   # change the password in mkdirs.cfg
   sed -e "s/=adminpass/=${P4_PASSWD}/g" \
      -e "s/=servicepass/=${P4_PASSWD}/g" \
      -e "s/=DNS_name_of_master_server_for_this_instance/=${P4_MASTER_HOST}/g" \
      -e "s/=\"example.com\"/=${P4_DOMAIN}/g" \
      -e "s/^SSL_PREFIX=/SSL_PREFIX=${P4_SSL_PREFIX}/g" \
      ${MkdirsCfgPath} > mkdirs.${SDP_INSTANCE}.cfg

   chmod +x mkdirs.sh

   msg "\\nSDP Localizations in mkdirs.cfg:"
   diff mkdirs.${SDP_INSTANCE}.cfg mkdirs.cfg

   run "./mkdirs.sh ${SDP_INSTANCE}"

   # Read P4ROOT/P4BIN
   source /p4/common/bin/p4_vars ${SDP_INSTANCE}

   # 2. Config for unicode
   if [ "${UNICODE_SERVER}" = "1" ]; then
      # See https://www.perforce.com/manuals/p4sag/Content/P4SAG/superuser.unicode.setup.html
      run "sudo -u perforce ${P4DInstanceScript} -r ${P4ROOT} -xi" \
         "Set Unicode (p4d -xi) for instance ${SDP_INSTANCE}." ||\
         bail "Failed to set Unicode."
   fi

   # 2.5. Setup SSL BEFORE starting the server if SSL is enabled
   if [[ "${P4PORT:-}" == ssl:* || "${P4_SSL_PREFIX:-}" == "ssl:" ]]; then
      msg "Setting up SSL certificates before starting server..."
      if ! /usr/local/bin/setup_ssl.sh; then
         warnmsg "Failed to setup SSL certificates, but continuing..."
      else
         msg "SSL certificates setup completed"
      fi
   fi
   
   # 3. Call configure_new_server.sh
   # This part references from:
   # https://swarm.workshop.perforce.com/projects/perforce_software-helix-installer/files/main/src/configure_sample_depot_for_sdp.sh

   # We must start the service before run configure_new_server.sh
   /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start

   if [ $P4_SSL_PREFIX == "ssl:" ]; then
      # Note: Automating a 'p4 trust -y' (especially with '-f') may not be appropriate
      # in a production environment, as it defeats the purpose of the Open SSL trust
      # mechanism.  But for our purposes here, where scripts spin up throw-away data
      # sets for testing or training purposes, it's just dandy.
      run "/p4/${SDP_INSTANCE}/bin/p4_${SDP_INSTANCE} -p $P4PORT trust -y -f" \
         "Trusting the OpenSSL Cert of the server." ||\
         bail "Failed to trust the server."
   fi

   run "${P4BIN} -s info -s" "Verifying direct connection to Perforce server." ||\
      bail "Could not connect to Perforce server."

   cd "${HxDepots}/sdp/Server/setup" ||\
      bail "Failed to cd to [${HxDepots}/sdp/Server/setup]."

   ConfigureNewServerBak="configure_new_server.sh.$(date +'%Y%m%d-%H%M%S').bak"
   run "mv -f configure_new_server.sh ${ConfigureNewServerBak}" \
      "Tweaking configure_new_server.sh settings to values more appropriate, e.g. reducing 5G storage limits." ||\
      bail "Failed to move configure_new_server.sh to ${ConfigureNewServerBak}."

   # Warning: If the values in configure_new_server.sh are changed from 5G, this will need to be updated.
   sed -e 's/filesys.P4ROOT.min=5G/filesys.P4ROOT.min=10M/g' \
      -e 's/filesys.depot.min=5G/filesys.depot.min=10M/g' \
      -e 's/filesys.P4JOURNAL.min=5G/filesys.P4JOURNAL.min=10M/g' \
      "${ConfigureNewServerBak}" >\
      configure_new_server.sh ||\
      bail "Failed to do sed substitutions in ${HxDepots}/sdp/Server/setup/${ConfigureNewServerBak}"

   run "chmod -x ${ConfigureNewServerBak}"
   run "chmod +x configure_new_server.sh"

   msg "Changes made to configure_new_server.sh:"
   diff "${ConfigureNewServerBak}" configure_new_server.sh
   
   run "./configure_new_server.sh ${SDP_INSTANCE}" \
      "Applying SDP configurables." ||\
      bail "Failed to set SDP configurables. Aborting."

   # IMPORTANT: Set critical configurables that might have been missed
   msg "Setting essential SDP configurables..."
   
   # Set journalPrefix - required for numbered journal rotation
   run "${P4BIN} configure set any:journalPrefix=/p4/${SDP_INSTANCE}/checkpoints/p4_${SDP_INSTANCE}" \
      "Setting journalPrefix configurable"
   
   # Set server.depot.root - required for depot file storage
   run "${P4BIN} configure set any:server.depot.root=/p4/${SDP_INSTANCE}/depots" \
      "Setting server.depot.root configurable"
   
   # Set additional recommended configurables
   run "${P4BIN} configure set monitor=1" \
      "Enabling monitor"
   
   # Set server description
   run "${P4BIN} configure set any:description='SDP Perforce Server for Unreal Engine'" \
      "Setting server description"
   
   # Verify the configurables were set
   msg "Verifying essential configurables:"
   ${P4BIN} configure show journalPrefix
   ${P4BIN} configure show server.depot.root
   ${P4BIN} configure show monitor

   # This part references configure-helix-p4d.sh, see
   # https://www.perforce.com/manuals/p4sag/Content/P4SAG/install.linux.packages.configure.html
   ADMINUSER=perforce

   # Populating the typemap
   ${P4BIN} typemap -i < ${CfgDir}/typemap.unreal.cfg
   
   # Initializing protections table.
   # In the p4-protect.cfg file, except user perforce, no other user of group can access depot by default.
   ${P4BIN} protect -i < ${CfgDir}/p4-protect.cfg
   
   # Setting password
   ${P4BIN} passwd -P ${P4_PASSWD} ${ADMINUSER}
   export P4PASSWD=${P4_PASSWD}

   #  Fixup .p4tickets, .p4trust
   chown perforce:perforce /p4/${SDP_INSTANCE}/.p4tickets
   chown perforce:perforce /p4/${SDP_INSTANCE}/.p4trust
   
   # Perform 1st live checkpoints
   run "sudo -u perforce /p4/common/bin/live_checkpoint.sh ${SDP_INSTANCE}"

   # Setting security level to 3 (high)
   # This will cause existing passwords reset.
   run "${P4BIN} configure set security=3"
   
   # 4. Finish
   /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init stop
else
   msg "Skip exiting instance configuring:"
   run "cat ${P4DInstanceScript}"
   
   # Even for existing instances, ensure critical configurables are set
   msg "Checking essential configurables for existing instance..."
   
   # Source the environment
   source /p4/common/bin/p4_vars ${SDP_INSTANCE}

   # Run SSL setup if either the env says ssl: or the server’s P4PORT is ssl:
   if [[ "${P4PORT:-}" == ssl:* || "${P4_SSL_PREFIX:-}" == "ssl:" ]]; then
      msg "Setting up SSL certificates before starting server..."
      if ! /usr/local/bin/setup_ssl.sh; then
         warnmsg "Failed to setup SSL certificates, but continuing..."
      else
         msg "SSL certificates setup completed"
      fi
   fi

   # Check if server is running
   # Ensure p4d is running so 'p4 configure' cannot silently fail
   NEED_STOP=0
   if ! /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status >/dev/null 2>&1; then
      msg "p4d not running; starting temporarily to apply configurables."
      if ! /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init start; then
         errmsg "p4d failed to start; check /p4/${SDP_INSTANCE}/logs/log and SSL perms if using ssl:"
         exit 1
      fi
      NEED_STOP=1
   fi

   # If SSL, pre-trust to avoid interactive trust prompts blocking configure
   if [[ "${P4PORT:-}" == ssl:* || "${P4_SSL_PREFIX:-}" == "ssl:" ]]; then
      /p4/${SDP_INSTANCE}/bin/p4_${SDP_INSTANCE} -p "$P4PORT" trust -y -f || true
   fi
      
   # Apply (idempotent) configurables unconditionally
   ${P4BIN} configure set any:journalPrefix=/p4/${SDP_INSTANCE}/checkpoints/p4_${SDP_INSTANCE}
   ${P4BIN} configure set any:server.depot.root=/p4/${SDP_INSTANCE}/depots
   ${P4BIN} configure set monitor=1

   # Optional: if a broker exists in common bin, create per-instance wrapper so verify_sdp passes
   if [[ -x /p4/common/bin/p4broker ]]; then
      mkdir -p /p4/${SDP_INSTANCE}/bin
      ln -sf /p4/common/bin/p4broker /p4/${SDP_INSTANCE}/bin/p4broker_${SDP_INSTANCE}
      [[ -x /p4/common/bin/p4broker_init ]] && \
         ln -sf /p4/common/bin/p4broker_init /p4/${SDP_INSTANCE}/bin/p4broker_${SDP_INSTANCE}_init || true
   fi

   msg "Essential configurables ensured."

   # Stop p4d if we started it solely for configuration
   if [[ $NEED_STOP -eq 1 ]]; then
      robust_p4d_stop "${SDP_INSTANCE}" 20
   fi
fi

run "sudo -u perforce crontab /p4/p4.crontab.${SDP_INSTANCE}"

# Verify the instance.
# Skip p4t_files, because after "configure set security=3", user need to reset password to login, so no tickets file.
/p4/common/bin/verify_sdp.sh ${SDP_INSTANCE} -skip license,offline_db,p4t_files || true