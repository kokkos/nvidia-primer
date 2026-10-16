# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

FROM nvcr.io/nvidia/cuda:13.0.2-devel-ubuntu22.04

# Install development tools
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        git build-essential ca-certificates openssh-client sudo vim nano gosu wget python3 libcap2 libdw1 libelf1 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Install CMake 3.28 from official releases
RUN wget -q https://github.com/Kitware/CMake/releases/download/v3.28.3/cmake-3.28.3-linux-x86_64.tar.gz && \
    tar -xzf cmake-3.28.3-linux-x86_64.tar.gz -C /opt && \
    rm cmake-3.28.3-linux-x86_64.tar.gz && \
    ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/cmake /usr/local/bin/cmake && \
    ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/ctest /usr/local/bin/ctest && \
    ln -sf /opt/cmake-3.28.3-linux-x86_64/bin/cpack /usr/local/bin/cpack

# Install Nsight Systems CLI 2025.6.1 for profiling
RUN wget -q https://developer.nvidia.com/downloads/assets/tools/secure/nsight-systems/2025_6/NsightSystems-linux-cli-public-2025.6.1.190-3689520.deb && \
    apt-get update -qq && \
    apt-get install -y -qq libglib2.0-0 && \
    dpkg -i NsightSystems-linux-cli-public-2025.6.1.190-3689520.deb && \
    rm NsightSystems-linux-cli-public-2025.6.1.190-3689520.deb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure sudo to allow any UID to use sudo without password
# This is needed when running with arbitrary --user UIDs
RUN echo 'ALL ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers && \
    chmod 0440 /etc/sudoers

# Pre-create /home/devuser directory with permissive ownership
# The entrypoint will fix ownership for the specific UID/GID
RUN mkdir -p /home/devuser && chmod 777 /home/devuser

# Pre-create X11 socket directory to avoid permission issues when attaching from VS Code
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Create an entrypoint that sets up the user and runs as that user
COPY <<'EOF' /entrypoint.sh
#!/bin/bash
set -e

# Create group if it doesn't exist
if ! getent group ${GROUP_ID} >/dev/null 2>&1; then
    groupadd -g ${GROUP_ID} devgroup
fi

# Create user if it doesn't exist, with bash as the shell
if ! getent passwd ${USER_ID} >/dev/null 2>&1; then
    useradd -u ${USER_ID} -g ${GROUP_ID} -d /home/devuser -s /bin/bash -m devuser
fi

# Set up CUDA environment if .bashrc doesn't exist
if [ ! -f /home/devuser/.bashrc ]; then
    cat > /home/devuser/.bashrc <<'EOFBASHRC'
# CUDA environment
export PATH=/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
export CUDA_HOME=/usr/local/cuda

# Standard bashrc
if [ -f /etc/bash.bashrc ]; then
    . /etc/bash.bashrc
fi

# Enable color prompt
export PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '

# Useful aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
EOFBASHRC
    chown ${USER_ID}:${GROUP_ID} /home/devuser/.bashrc
fi

# Set up SSH agent permissions if needed
if [ -n "${SSH_AUTH_SOCK}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
    SSH_SOCK_DIR=$(dirname "${SSH_AUTH_SOCK}")
    chmod 755 "${SSH_SOCK_DIR}" 2>/dev/null || true
    chmod 666 "${SSH_AUTH_SOCK}" 2>/dev/null || true
fi

# Configure root's bashrc to auto-switch to devuser
# This ensures that docker exec (which defaults to root) will become devuser
cat > /root/.bashrc <<'EOFROOTBASHRC'
# Auto-switch to devuser if running as root in an interactive shell
if [ "$(id -u)" = "0" ] && [ -n "$BASH_VERSION" ] && [ -t 0 ]; then
    export HOME=/home/devuser
    cd /home/devuser 2>/dev/null || cd /
    exec gosu devuser bash --login
fi
EOFROOTBASHRC

# Switch to devuser and execute the command
exec gosu devuser "$@"
EOF

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["sleep", "infinity"]
