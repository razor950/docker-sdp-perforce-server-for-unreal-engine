### Base image with SDP prerequisites.
# Multi stage build is more cache friendly, modify part of the Dockerfile will not cause all the files to be redownloaded.

# Specifies the Ubuntu version for the base image. Check Perforce documentation for supported versions.
# See: https://www.perforce.com/manuals/p4sag/Content/P4SAG/install.linux.packages.html
ARG UBUNTU_VERSION=jammy

FROM ubuntu:${UBUNTU_VERSION} as base

##  Install system prerequisites used by SDP.
# 1. cron: for running SDP cron jobs
# 2. curl: for downloading SDP
# 3. file: used by verify_sdp.sh
# 4. mailutils: SDP maintance script will call mail command
# 5. sudo: for running commands as another user
RUN apt-get update && apt-get install -y \
    cron \
    curl \
    file \
    mailutils \
    sudo \
 && rm -rf /var/lib/apt/lists/*

### Download SDP stage
FROM base as stage1

COPY files_for_build/1/* /tmp

# Specify the SDP version. If SDP_VERSION is empty, the download_sdp.sh script attempts to fetch the latest.
# It's recommended to set a specific version for reproducible builds.
ARG SDP_VERSION=2024.1.30385

# Download SDP
RUN /bin/bash -x /tmp/setup_container.sh\
&& export SDPVersion=.${SDP_VERSION} \
&& /bin/bash -x /tmp/download_sdp.sh \
&& rm -rf /tmp/*

### Download Helix binaries stage
FROM stage1 as stage2

# Specify the Perforce Helix Core binaries version (e.g., r23.2, r24.1).
ARG P4_VERSION=r24.1

# Comma-separated list of Helix binaries to download. 'p4' (client) and 'p4d' (server) are minimal.
# Others could include 'p4broker', 'p4p', 'p4merge', etc., depending on needs.
# The script 'get_helix_binaries.sh' handles the download based on this list.
ARG P4_BIN_LIST=p4,p4d

COPY files_for_build/2/* /tmp/sdp/helix_binaries/

RUN export P4Version=${P4_VERSION}\
&& export P4BinList=${P4_BIN_LIST}\
&& /bin/bash -x /tmp/sdp/helix_binaries/download_p4d.sh\
&& rm -rf /tmp/*

### Final stage
FROM stage2 as stage3

# Build-time argument for the version control reference (e.g., git commit hash)
ARG VCS_REF=unspecified
# Build-time argument for the build date
ARG BUILD_DATE=unspecified

LABEL org.label-schema.name="sdp-perforce" \
      org.label-schema.description="SDP Perforce for Unreal Engine" \
      org.label-schema.build-date="${BUILD_DATE}" \
      org.label-schema.vcs-url="https://github.com/razor950/docker-sdp-perforce-server-for-unreal-engine" \
      org.label-schema.vcs-ref="${VCS_REF}" \
      org.label-schema.version="sdp.${SDP_VERSION}-helix.${P4_VERSION}-${UBUNTU_VERSION}" \
      org.label-schema.schema-version="1.0" \
      maintainer="razor950"

# Port for perforce server
EXPOSE 1666

# The meaning of each volumn, see:
# https://swarm.workshop.perforce.com/projects/perforce-software-sdp/view/main/doc/SDP_Guide.Unix.html#_volume_layout_and_hardware
VOLUME [ "/hxmetadata", "/hxdepots", "/hxlogs", "/p4" ]

COPY --chmod=0755 files_for_run/* /usr/local/bin/

# For first running a P4 Instance.
# P4_PASSWD is used for init perforce instance, 
# after "configure set security=3" is called, when you login to Perforce server for the first time, you will be asked to change the password.
ENV SDP_INSTANCE=1 UNICODE_SERVER=1 P4_MASTER_HOST=127.0.0.1 P4_DOMAIN=example.com P4_SSL_PREFIX=

ENTRYPOINT ["/usr/local/bin/docker_entry.sh"]
