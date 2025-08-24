#!/bin/bash
#==============================================================================
# Copyright and license info is available in the LICENSE file included with
# the Server Deployment Package (SDP), and also available online:
# https://swarm.workshop.perforce.com/projects/perforce-software-sdp/view/main/LICENSE
#------------------------------------------------------------------------------
set -u

# This script acquires Perforce Helix binaries from the Perforce FTP server.
# For documentation, run: get_helix_binaries.sh -man
# Typical usage:
#   cd /p4/sdp/helix_binaries
#   ./get_helix_binaries.sh

#==============================================================================
# Declarations and Environment

declare ThisScript=${0##*/}
declare Version=1.7.4
declare ThisUser=
declare ThisHost=${HOSTNAME%%.*}
declare -i Debug=${SDP_DEBUG:-0}
declare -i NoOp=0
declare -i ErrorCount=0
declare -i WarningCount=0
declare -i RetryCount=0
declare -i RetryMax=2
declare -i RetryDelay=2
declare -i RetryOK=0
declare -i DownloadAPIs=0
declare HelixVersion=
declare DefaultHelixVersion=r25.1
declare DefaultBinList="p4 p4d p4broker p4p"
declare StageBinDir=
declare BinList=
declare Platform=
declare PerforceFTPBaseURL="https://ftp.perforce.com/perforce"
declare BinURL=
declare APIURL=
declare APIDirURL=
declare APIDirHTML=
declare APIFiles=
declare Cmd=
declare Cmd2=
declare VersionCheckFile=

declare OSArch=
declare OSName=
declare OSVersionString=
declare OSMajorVersion=
declare OSMinorVersion=

#==============================================================================
# Local Functions

function msg () { echo -e "$*"; }
function dbg () { [[ "$Debug" -eq 0 ]] || msg "DEBUG: $*"; }
function errmsg () { msg "\\nError: ${1:-Unknown Error}\\n"; ErrorCount+=1; }
function warnmsg () { msg "\\nWarning: ${1:-Unknown Warning}\\n"; WarningCount+=1; }
function bail () { errmsg "${1:-Unknown Error}"; exit "${2:-1}"; }

#------------------------------------------------------------------------------
# Function: set_platform
#
# Determine the <Platform> value to used in the URL for the FTP server.
#
# Set value for global $Platform 
#------------------------------------------------------------------------------
function set_platform () {
   local binary=${1:-}
   local osCompatName osMajorVersionCompat osMinorVersionCompat
   local jsonFile=
   local binDir=
   local platformsAvailable=

   Platform="PlatformUnsetForBinary-$binary"

   # If the 'jq' utility is available, parse the json files to verify that there
   # is a build available for the detected platform, by parsing the P4*.json
   # release list files.
   if [[ -n "$(command -v jq)" ]]; then
      # If the '-sbd <StageBinDir>' option was used, search for the P4*.json
      # in that directory. Otherwise, use the standard SDP location.
      if [[ -n "$StageBinDir" ]]; then
         binDir="$StageBinDir"
      else
         binDir="${SDP_INSTALL_ROOT:-/p4}/sdp/helix_binaries"
      fi

      case "${binary:-unset}" in
         (p4) jsonFile=${binDir}/P4.json;;
         (p4d) jsonFile=${binDir}/P4D.json;;
         (p4broker) jsonFile=${binDir}/P4Broker.json;;
         (p4p) jsonFile=${binDir}/P4Proxy.json;;
         (unset) bail "Bad call to set_platform(); parameter 1 (binary) required.";;
      esac

      if [[ -n "$jsonFile" ]]; then
         if [[ -r "$jsonFile" ]]; then
            platformsAvailable=$(jq -r '.versions[].platform' "$jsonFile" | tr '\n' ' ')
         else
            warnmsg "Cannot read the versions json file: $jsonFile"
         fi
      else
         warnmsg "Could not determine versions json file for binary $binary."
      fi
   else
      dbg "The 'jq' utility is not available. Consider installing it to verify platform availability and suggest alternate platform options."
   fi

   # Static configuration for P4D OS Version compatibility. This supports only
   # a subset of possible OS/platforms for p4d, to include all versions supported
   # by OS installation packages.
   case "$OSName" in
      (Linux)
         osCompatName=linux
         osMajorVersionCompat=2
         osMinorVersionCompat=6
      ;;
      (Darwin)
         osCompatName=macosx
         if (( OSMajorVersion >= 12 )); then
            osMajorVersionCompat=12
            osMinorVersionCompat=
         elif (( OSMajorVersion == 11 )); then
            osMajorVersionCompat=11
            osMinorVersionCompat=01
         elif (( OSMajorVersion == 10 )); then
            if (( OSMinorVersion >= 15 )); then
               osMajorVersionCompat=10
               osMinorVersionCompat=15
            elif (( OSMinorVersion >= 10 )); then
               osMajorVersionCompat=10
               osMinorVersionCompat=10
            else
               osMajorVersionCompat=10
               osMinorVersionCompat=5
            fi
         fi
      ;;
      (*)
         osCompatName=linux
         osMajorVersionCompat=2
         osMinorVersionCompat=6
         warnmsg "Could not determine OS version compatibility for this OS: $OSName. Using default [$osCompatName$osMajorVersionCompat$osMinorVersionCompat]."
      ;;
   esac

   dbg "
OSArch:                $OSArch
OSName:                $OSName
osCompatName:          $osCompatName

OSVersionString:       $OSVersionString

OSMajorVersion:        $OSMajorVersion
OSMinorVersion:        $OSMinorVersion

osMajorVersionCompat:  $osMajorVersionCompat
osMinorVersionCompat:  $osMinorVersionCompat
"

   # shellcheck disable=SC2071
   if (( OSMajorVersion < osMajorVersionCompat )); then
      warnmsg "OS Kernel Major Version ($OSMajorVersion) is less than Helix OS major version compatibility for $OSName, ($osMajorVersionCompat). The downloaded binary may not be suitable for this platform."
   elif (( OSMajorVersion == osMajorVersionCompat )) && (( OSMinorVersion < osMinorVersionCompat )); then
      warnmsg "OS Kernel Minor Version ($OSMajorVersion.$OSMinorVersion) is less than Helix OS minor version compatibility for $OSName, ($osMajorVersionCompat.$osMinorVersionCompat). The downloaded binary may not be suitable for this platform."
   fi

   # Platform should look like linux26x86_64, macosx1015x86_64
   Platform="${osCompatName}${osMajorVersionCompat}${osMinorVersionCompat}${OSArch}"

   # If the jq utility is available and a list of platforms could be determined, use that
   # information to verify that a build is available for the detected platform.
   if [[ -n "$platformsAvailable" ]]; then
      if [[ "$platformsAvailable" =~ $Platform ]]; then
         dbg "Verified: A build is available for detected platform [$Platform]."
      else
         dbg "No build available for detected platform [$Platform]. Checking fallback options ..."

         # Hard-coded enumeration of cases where, for the p4* binaries, a good fallback option
         # exists.
         case "$Platform" in
            (macosx12x86_64) Platform=macosx1015x86_64; dbg "Using alternate platform: $Platform";;
            (*) warnmsg "There does not appear to be a build available for detected platform [$Platform].";;
         esac
      fi
   else
      dbg "Platform available list was empty."
   fi

   msg "Using $binary build for platform: $Platform"
}

#------------------------------------------------------------------------------
# Function: usage (required function)
#
# Input:
# $1 - style, either -h (for short form) or -man (for man-page like format).
# The default is -h.
#
# $2 - error message (optional).  Specify this if usage() is called due to
# user error, in which case the given message displayed first, followed by the
# standard usage message (short or long depending on $1).  If displaying an
# error, usually $1 should be -h so that the longer usage message doesn't
# obscure the error message.
#
# Sample Usage:
# usage 
# usage -man
# usage -h "Incorrect command line usage."
#
# This last example generates a usage error message followed by the short
# '-h' usage summary.
#------------------------------------------------------------------------------
function usage {
   declare style=${1:--h}
   declare errorMessage=${2:-Unset}

   if [[ $errorMessage != Unset ]]; then
      msg "\\n\\nUsage Error:\\n\\n$errorMessage\\n\\n"
   fi

msg "USAGE for $ThisScript v$Version:

$ThisScript [-r <HelixMajorVersion>] [-b <Binary1>,<Binary2>,...] [-api] [-sbd <StageBinDir>] [-n] [-d|-D]

   or

$ThisScript -h|-man"
   if [[ $style == -man ]]; then
      msg "
DESCRIPTION:
	This script acquires Perforce Helix binaries from the Perforce FTP server.

	The four Helix binaries that can be acquired are:

	* p4, the command line client
	* p4d, the Helix Core server
	* p4p, the Helix Proxy
	* p4broker, the Helix Broker

	In addition, P4API, the C++ client API, can be downloaded.

	This script gets the latest patch of binaries for the current major Helix
	version.  It is intended to acquire the latest patch for an existing install,
	or to get initial binaries for a fresh new install.  It must be run from
	the /p4/sdp/helix_binaries directory in order for the upgrade.sh script
	to find the downloaded binaries.

	The helix_binaries directory is used for staging binaries for later upgrade
	with the SDP 'upgrade.sh' script (documented separately).  This helix_binaries
	directory is used to stage binaries on the current machine, while the
	'upgrade.sh' script uses the downloaded binaries to upgrade a single SDP
	instance (of which there might be several on a machine).

	The helix_binaries directory must NOT be in the PATH. As a safety feature,
	the 'verify_sdp.sh' will report an error if the 'p4d' binary is found outside
	/p4/common/bin in the PATH. The SDP 'upgrade.sh' check uses 'verify_sdp.sh'
	as part of its preflight checks, and will refuse to upgrade if any 'p4d' is
	found in the PATH outside /p4/common/bin.

	When a newer major version of Helix binaries is needed, this script should not
	be modified directly. Instead, get the latest version of SDP first, which will
	included a newer version of this script, as well as the latest 'upgrade.sh'
	The 'upgrade.sh' script is updated with each major SDP version to be aware of
	any changes in the upgrade procedure for the corresponding p4d version.
	Upgrading SDP first ensures you have a version of the SDP that works with
	newer versions of p4d and other Helix binaries.

PLATFORM DETECTION
	The 'uname' command is used to determine the architecture for the current
	machine on which this script is run.

	This script and supporting P4*.json release list files know what platforms
	for which builds are available for each Helix Core binary (p4, p4d, p4broker,
	p4p).  If the 'jq' utility is available, this script uses the P4*.json files
	to verify that a build is available for the current platform, and in some
	cases selects an alternate compatible platform if needed. For example, if
	the detected platform is for OSX 12+ for the x86_64 architecture, no build
	is available for binaries such as p4d for that platform, so a compatible
	alternative is used instead, in this case macosx1015x86_64.
	
	This script handles only the UNIX/Linux platforms (to include OSX).

RELEASE LIST FILES:
	For each binary, there is a corresponding release list file (in json format)
	that indicates the platforms available for the given binary.  These files are:

	P4.json (for the 'p4' binary)
	P4D.json (for the 'p4d' binary)
	P4Broker.json (for the 'p4broker' binary)
	P4Proxy.json (for the 'p4p' binary)

	These P4*.json release list files are aware of a wide list of supported
	platforms for a range of Helix Core binaries.

	These release list files are packaged with the SDP, and updated for each
	major release.

OPTIONS:
 -r <HelixMajorVersion>
	Specify the Helix Version, using the short form.  The form is rYY.N, e.g. r21.2
	to denote the 2021.2 release. The default: is $DefaultHelixVersion

	The form of 'rYY.N', e.g. 'r25.1', is the default form of the version, matching
	what is used in URLS on the Perforce Helix FTP server.  For flexibility, similar
	forms that clearly convent the intended version are also accepted.  For example:

	'-r 23.1' is implicitly converted to '-r r23.1'.
	'-r 2023.1' is implicitly converted to ' -r r23.1'.

 -b <Binary1>[,<Binary2>,...]
	Specify a comma-delimited list of Helix binaries. The default is: $DefaultBinList

	Alternately, specify '-b none' in conjunction with '-api' to download only APIs
	and none of the p4* binaries.

 -api
	Specify '-api' to download P4API, the C++ client API.  This will acquire one or
	more client API tarballs, depending on the current platform.  The API files will
	look something like these examples:

	* p4api-glibc2.3-openssl1.1.1.tgz
	* p4api-glibc2.3-openssl3.tgz
	* p4api-glibc2.12-openssl1.1.1.tgz
	* p4api-glibc2.12-openssl3.tgz

	* p4api-openssl1.1.1.tgz
	* p4api-openssl3.tgz

	All binaries that match 'p4api*tgz' in the relevant directory on the Perforce
	FTP server for the current architecture and Helix Core version are downloaded.

	Unlike binary downloads, the old versions are not checked, because file names are
	fixed as they are with binaries.

	APIs are not needed for normal operations, and are only downloaded if requested
	with the '-api' option. They may be useful for developing custom automation such
	as custom triggers.  Be warned, custom triggers are not supported by Perforce Support.

 -sbd <StageBinDir>
 	Specify the staging directory to install downloaded binaries.
	
	By default, this script downloads files into the current directory, which
	is expected and required to be /p4/sdp/helix_binaries.  Documented workflows
	for using this script involve first cd'ing to that directory.  Using this
	option disables the expected directory check and allows binaries to be
	installed in any directory, which may be useful if this script is used
	as a standalone script outside the SDP (e.g. for setting up test
	environments or enabling Helix native DVCS features by installing binaries
	into /usr/local/bin on a non-SDP machine.

	This option also sets the location in which this script searches for the
	P4*.json release list files.

 -n	Specify the '-n' (No Operation) option to show the commands needed
	to fetch the Helix binaries from the Perforce FTP server without attempting
	to execute them.

 -d	Set debugging verbosity.

 -D	Set extreme debugging verbosity using bash 'set -x' mode. Implies '-d'.

HELP OPTIONS:
 -h	Display short help message
 -man	Display this manual page

EXAMPLES:
	Example 1 - Typical Usage with no arguments:

	cd /p4/sdp/helix_binaries
	./get_helix_binaries.sh

	This acquires the latest patch of all 4 binaries for the $DefaultHelixVersion
	release (aka 20${DefaultHelixVersion#r}).

	This will not download APIs, which are not needed for general operation.

	Example 2 - Specify the major version:

	cd /p4/sdp/helix_binaries
	./get_helix_binaries.sh -r r21.2

	This gets the latest patch of for the 2021.2 release of all 4 binaries.

	Note: Only supported binaries are guaranteed to be available from the
	Perforce FTP server.

	Note: Only the latest patch for any given major release is available from the
	Perforce FTP server.

	Example 3 - Get r22.2 and skip the proxy binary (p4p):

	cd /p4/sdp/helix_binaries
	./get_helix_binaries.sh -r r22.2 -b p4,p4d,p4broker

	Example 4 - Download r23.1 binaries in a non-default directory.

	cd /any/directory/you/want
	./get_helix_binaries.sh -r r23.1 -sbd .

	or:

	./get_helix_binaries.sh -r r23.2 -sbd /any/directory/you/want

	Example 5 - Download C++ client API only:

	./get_helix_binaries.sh -r r24.1 -b none -api

DEPENDENCIES:
	This script requires outbound internet access. Depending on your environment,
	it may also require HTTPS_PROXY to be defined, or may not work at all.

	If this script doesn't work due to lack of outbound internet access, it is
	still useful illustrating the locations on the Perforce FTP server where
	Helix Core binaries can be found.  If outbound internet access is not
	available, use the '-n' flag to see where on the Perforce FTP server the
	files must be pulled from, and then find a way to get the files from the
	Perforce FTP server to the correct directory on your local machine,
	/p4/sdp/helix_binaries by default.

EXIT CODES:
	An exit code of 0 indicates no errors were encountered. An
	non-zero exit code indicates errors were encountered.
"
   fi

   exit 1
}

#==============================================================================
# Command Line Processing

declare -i shiftArgs=0

set +u
while [[ $# -gt 0 ]]; do
   case $1 in
      (-h) usage -h;;
      (-man) usage -man;;
      (-r) HelixVersion="${2:-}"; shiftArgs=1;;
      (-b) BinList="${2:-}"; shiftArgs=1;;
      (-api) DownloadAPIs=1;;
      (-sbd) StageBinDir="${2:-}"; shiftArgs=1;;
      (-n) NoOp=1;;
      (-d) Debug=1;;
      (-D) Debug=1; set -x;; # Debug; use 'set -x' mode.
      (-*) usage -h "Unknown option [$1].";;
      (*) usage -h "Unknown command line fragment [$1].";;
   esac

   # Shift (modify $#) the appropriate number of times.
   shift; while [[ $shiftArgs -gt 0 ]]; do
      [[ $# -eq 0 ]] && usage -h "Incorrect number of arguments."
      shiftArgs=$shiftArgs-1
      shift
   done
done
set -u

#==============================================================================
# Command Line Verification

if [[ -n "$HelixVersion" ]]; then
   # Verify values provided for the HelixVersion. By default we use the form
   # used in URLs on the Perforce FTP server, which is where this script pulls
   # binaries from. That form is 'rYY.N', e.g. 'r24.1' for the 2024.1 release.

   # If HelixVersion looks like 'YY.N', convert to 'rYY.N'.
   if [[ "$HelixVersion" =~ ^[0-9]{2}[.]{1}[0-9]{1}$ ]]; then
      HelixVersion="r$HelixVersion"
      dbg "HelixVersion value implicitly converted to $HelixVersion."
   # If HelixVersion looks like 'YYYY.N', convert to 'rYY.N', but
   # first check if the YYYY is valid.
   elif [[ "$HelixVersion" =~ ^[0-9]{4}[.]{1}[0-9]{1}$ ]]; then
      YYYY=$(echo "$HelixVersion" | cut -c 1-4)
      case "$YYYY" in
         199*) : ;;
         200*) : ;;
         201*) : ;;
         2020) : ;;
         2021) : ;;
         2022) : ;;
         2023) : ;;
         2024) : ;;
         *) usage -h "No Helix Core version was released in the year ($YYYY) specified with '-r $HelixVersion'.";;
      esac

      HelixVersion=r$(echo "$HelixVersion" | cut -c 3-)
      dbg "HelixVersion value implicitly converted to $HelixVersion."
   # If HelixVersion looks like 'rYY.N', no conversion needed.
   elif [[ "$HelixVersion" =~ ^r[0-9]{2}[.]{1}[0-9]{1}$ ]]; then
      :
   else
      usage -h "The format of the Helix Version specified with '-r $HelixVersion' is invalid. The expected form is '-r rYY.N'. For example, use '-r r23.2' to specify the 2023.2 release."
   fi
else
   HelixVersion="$DefaultHelixVersion"
fi

[[ -n "$BinList" ]] || BinList="$DefaultBinList"

# If '-b none' was specified and '-api' was not, give a usage error.
[[ "$BinList" == none && "$DownloadAPIs" -eq 0 ]] && \
   usage -h "Nothing to download; '-b none' was specified and '-api' was not. Did you mean '-b none -api'?"

# If '-b none' was specified, clear the BinList.
[[ "$BinList" == none ]] && BinList=

if [[ -n "$StageBinDir" ]]; then
   cd "$StageBinDir" || bail "Could not do: cd \"$StageBinDir\""
else
   [[ "$PWD" == *"/sdp/helix_binaries" ]] || bail "This $ThisScript script is being run from directory $PWD, not /p4/sdp/helix_binaries, and '-sbd <staging_dir>' was not specified."
fi

if [[ ! "$HelixVersion" =~ ^r[0-9]{2}\.[0-9]{1}$ ]]; then
   usage -h "\\n\\tThe Helix Version specified with '-r $HelixVersion' is invalid.\\n\\tIt should look like: $DefaultHelixVersion\\n"
fi

#==============================================================================
# Main Program

ThisUser=$(id -n -u)
msg "\\nStarted $ThisScript v$Version as $ThisUser@$ThisHost at $(date)."

OSArch=$(uname -m)
OSName=$(uname -s)
OSVersionString=$(uname -r)
OSMajorVersion=${OSVersionString%%.*}
OSMinorVersion=${OSVersionString%.*}
OSMinorVersion=${OSMinorVersion#*.}

VersionCheckFile=$(mktemp)

for binary in $(echo "$BinList"|tr ',' ' '); do
   msg "\\nGetting $binary ..."
   set_platform "$binary" || bail "Could not determine platform for binary $binary."
   BinURL="${PerforceFTPBaseURL}/${HelixVersion}/bin.${Platform}/$binary"
   if [[ -f "$binary" ]]; then
      chmod +x "$binary"
      "./$binary" -V > "$VersionCheckFile" 2>&1
      if grep -q Rev "$VersionCheckFile"; then
         msg "Old version of $binary: $(grep Rev "$VersionCheckFile")"
      else
         # If we cannot get the version information from the binary on the disk at the
         # start of processing, display a warning.
         warnmsg "Could not extract version information from old/existing $binary binary with: $binary -V"
      fi

      if [[ "$NoOp" -eq 0 ]]; then
         rm -f "$binary"
      fi
   fi

   Cmd="curl -s -O $BinURL"

   if [[ "$NoOp" -eq 1 ]]; then
      msg "NoOp: Would run: $Cmd"
      continue
   else
      msg "Running: $Cmd"
   fi

   if $Cmd; then
      chmod +x "$binary"
      "./$binary" -V > "$VersionCheckFile" 2>&1
      # If we cannot get the version information from the newly downloaded binary, that is a hard error.
      if grep -q Rev "$VersionCheckFile"; then
         msg "New version of $binary: $(grep Rev "$VersionCheckFile")"
      else
         errmsg "Could not extract version information from newly downloaded $binary binary with: $binary -V"
      fi
   else
      # Replace the '-s' silent flag with '-v' after we have had an error, to
      # help with debugging.
      Cmd="curl -v -O $BinURL"
      warnmsg "Failed to download $binary with this URL: $BinURL\\nRetrying ..."
      RetryCount=0

      while [[ "$RetryCount" -le "$RetryMax" ]]; do
         RetryCount+=1
         sleep "$RetryDelay"
         msg "Retry $RetryCount of $binary with command: $Cmd"
         if $Cmd; then
            chmod +x "$binary"
            msg "New version of $binary: $("./$binary" -V | grep Rev)"
            RetryOK=1
            break
         else
            warnmsg "Retry $RetryCount failed again to download $binary with this URL: $BinURL"
         fi
      done

      if [[ "$RetryOK" -eq 0 ]]; then
         errmsg "Failed to download $binary with this URL: $BinURL"
         rm -f "$binary"
      fi
   fi
done

if [[ "$DownloadAPIs" -eq 1 ]]; then
   msg "Downloading P4API."
   set_platform "p4" || bail "Could not determine platform for binary p4."
   APIDirURL="${PerforceFTPBaseURL}/${HelixVersion}/bin.${Platform}"
   APIDirHTML=$(mktemp)

   Cmd="curl -L -s -o $APIDirHTML $APIDirURL"
   msg "Getting list of APIs for ${HelixVersion}/bin.${Platform}."
   msg "Running: $Cmd"

   # Note: We attempt to get the list of APIs even in NoOp mode.
   if $Cmd; then
      APIFiles=$(grep 'href="p4api' "$APIDirHTML" | sed -E -e 's|^.* href="||g' -e 's|".*$||g')

      [[ -n "$APIFiles" ]] || bail "No APIs found for $HelixVersion/bin.${Platform}."

      for apiFile in $APIFiles; do
         APIURL="$APIDirURL/$apiFile"
         Cmd2="curl -s -O $APIURL"
         if [[ "$NoOp" -eq 1 ]]; then
            msg "NoOp: Would run: $Cmd2"
            continue
         else
            msg "Running: $Cmd2"
         fi

         if $Cmd2; then
            tar -tzf "$apiFile" | head -1 | cut -d '/' -f 1 > "$VersionCheckFile"
            # If we cannot get the version information from the newly downloaded API, report an error.
            if grep -q p4api- "$VersionCheckFile"; then
               msg "New version of $apiFile: $(cat "$VersionCheckFile")"
            else
               errmsg "Could not extract version information from newly downloaded API tarball: tar -tzf $apiFile"
            fi
         else
            errmsg "Could not download API with this command: $Cmd2"
         fi
      done
   else
      errmsg "Failed to download API dir info with this URL: $APIDirURL. Aborting."
   fi
fi

rm -f "$VersionCheckFile"

if [[ "$ErrorCount" -eq 0 ]]; then
   msg "\\nDownloading of Perforce Helix files completed OK."
else
   errmsg "\\nThere were $ErrorCount errors attempting to acquire Perforce Helix files."
fi

exit "$ErrorCount"
