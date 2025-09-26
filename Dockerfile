### Base image with SDP prerequisites.
# Multi stage build is more cache friendly, modify part of the Dockerfile will not cause all the files to be redownloaded.

# For which ubuntu version perforce supported, see:
# https://www.perforce.com/manuals/p4sag/Content/P4SAG/install.linux.packages.html
ARG UBUNTU_VERSION=jammy

FROM ubuntu:${UBUNTU_VERSION} AS base

##  Install system prerequisites used by SDP.
# 1. cron: for running SDP cron jobs
# 2. curl: for downloading SDP
# 3. file: used by verify_sdp.sh
# 4. mailutils: SDP maintance script will call mail command
# 5. sudo: for running commands as another user
# 6. ca-certificates: for secure downloads
# 7. gnupg: for package verification
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    cron \
    curl \
    file \
    gnupg \
    mailutils \
    sudo \
    rsync \
    openssl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

### Download SDP stage
FROM base AS stage1

# Copy files with specific ownership
COPY --chown=root:root files_for_build/1/* /tmp/

# Specify the SDP version, if SDP_VERSION is empty, the latest SDP will be downloaded.
ARG SDP_VERSION=2025.1.31674

# Debug: Check what files we have and run setup step by step
RUN echo "=== Debug: Checking copied files ===" \
 && ls -la /tmp/ \
 && echo "=== Debug: Running setup_container.sh ===" \
 && chmod +x /tmp/setup_container.sh \
 && /bin/bash -x /tmp/setup_container.sh \
 && echo "=== Debug: Running download_sdp.sh ===" \
 && chmod +x /tmp/download_sdp.sh \
 && export SDPVersion=.${SDP_VERSION} \
 && /bin/bash -x /tmp/download_sdp.sh \
 && echo "=== Debug: Cleaning up ===" \
 && rm -rf /tmp/* /var/tmp/*

### Download Helix binaries stage
FROM stage1 AS stage2

# P4 binaries version
ARG P4_VERSION=r25.1

# For minimal usage, only p4 and p4d need to be downloaded.
# Fixed typo: p4ds should be p4d
ARG P4_BIN_LIST=p4,p4d,p4broker,p4p

# Create helix_binaries directory and copy files
RUN mkdir -p /tmp/sdp/helix_binaries

COPY --chown=root:root files_for_build/2/* /tmp/sdp/helix_binaries/

# Debug: Check files and download binaries step by step
RUN export P4Version=${P4_VERSION}\
&& export P4BinList=${P4_BIN_LIST}\
&& /bin/bash -x /tmp/sdp/helix_binaries/download_p4d.sh\
&& rm -rf /tmp/*

### Final stage
FROM stage2 AS final

ARG VCS_REF=unspecified
ARG BUILD_DATE=unspecified
ARG SDP_VERSION=2025.1.31674
ARG P4_VERSION=r25.1
ARG UBUNTU_VERSION=jammy

# Use standard labels instead of deprecated label-schema
LABEL org.opencontainers.image.title="SDP Perforce for Unreal Engine" \
      org.opencontainers.image.description="Docker perforce server using SDP, configured for Unreal Engine" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/zhaojunmeng/docker-sdp-perforce-server-for-unreal-engine" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="sdp.${SDP_VERSION}-helix.${P4_VERSION}-${UBUNTU_VERSION}" \
      org.opencontainers.image.vendor="zhaojunmeng" \
      org.opencontainers.image.licenses="MIT"

# Port for perforce server
EXPOSE 1666

# The meaning of each volume, see:
# https://swarm.workshop.perforce.com/projects/perforce-software-sdp/view/main/doc/SDP_Guide.Unix.html#_volume_layout_and_hardware
VOLUME ["/hxmetadata", "/hxdepots", "/hxlogs", "/p4"]

# Copy runtime files with proper permissions
COPY --chmod=0755 --chown=root:root files_for_run/* /usr/local/bin/

# Create necessary directories with proper ownership
# Note: perforce user will be created by setup_container.sh, so we use root here
RUN mkdir -p /hxmetadata /hxdepots /hxlogs /p4

# Configure sudo for perforce user (after user is created by setup_container.sh)
RUN echo "perforce ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/perforce \
 && chmod 0440 /etc/sudoers.d/perforce

# Health check to ensure Perforce is running
#HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
#  CMD /p4/${SDP_INSTANCE}/bin/p4d_${SDP_INSTANCE}_init status || exit 1

# For first running a P4 Instance, you can change the default P4_PASSWD variable.
# P4_PASSWD is used for init perforce instance, 
# after "configure set security=3" is called, when you login to Perforce server for the first time, you will be asked to change the password.
# Note: This is a default password that MUST be changed on first login due to security=3
ENV SDP_INSTANCE=1 \
    P4_PASSWD=F@stSCM! \
    UNICODE_SERVER=0 \
    P4_MASTER_HOST=127.0.0.1 \
    P4_DOMAIN=example.com \
    P4_SSL_PREFIX= \
    BACKUP_DESTINATION= \
    BACKUP_RETENTION_WEEKS=52 \
    BACKUP_SAFE_MODE=1

# Note: We cannot switch to perforce user here since it doesn't exist yet
# The user will be created when the container starts via setup_container.sh
# USER perforce

ENTRYPOINT ["/usr/local/bin/docker_entry.sh"]