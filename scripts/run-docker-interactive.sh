#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Script to launch an interactive Docker environment
# This provides a consistent development environment without running CI tests
#
# Usage:
#   ./run-docker-interactive.sh

set -e

# Container workspace
PROJECT_DIR="/tmp/nvidia-primer"

# Get absolute path to the project root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(realpath "$SCRIPT_DIR")"

IMAGE="kokkos-dev-env:latest"

echo "Starting interactive Docker environment..."
echo "Project directory (host): $SCRIPT_DIR"
echo "Project directory (container): $PROJECT_DIR"
echo "Docker image: $IMAGE"
echo ""

# Verify the directory exists
if [ ! -d "$SCRIPT_DIR" ]; then
    echo "ERROR: Directory does not exist: $SCRIPT_DIR"
    exit 1
fi

# Check Docker
echo "Checking Docker..."
docker info > /dev/null 2>&1 || {
    echo "ERROR: Docker is not running or not accessible"
    exit 1
}

# Build SSH mount options
SSH_MOUNTS=""
SSH_ENV=""
if [ -S "${SSH_AUTH_SOCK}" ] || [ -L "${SSH_AUTH_SOCK}" ]; then
    # Resolve symlink to get the real socket path (VS Code Remote-SSH uses symlinks)
    REAL_SSH_SOCK=$(readlink -f "${SSH_AUTH_SOCK}")
    
    if [ -S "$REAL_SSH_SOCK" ]; then
        # Get the directory containing the actual socket
        SSH_SOCK_DIR="$(dirname "${REAL_SSH_SOCK}")"
        
        # Mount the directory and use the real socket path
        SSH_MOUNTS="-v ${SSH_SOCK_DIR}:${SSH_SOCK_DIR}:ro"
        SSH_ENV="-e SSH_AUTH_SOCK=${REAL_SSH_SOCK}"
        echo "SSH agent forwarding: enabled (${REAL_SSH_SOCK})"
    else
        echo "WARNING: SSH socket symlink found but target doesn't exist"
        echo "SSH agent forwarding: disabled"
    fi
else
    echo "SSH agent forwarding: disabled (SSH_AUTH_SOCK not set)"
fi

# Get current user's UID and GID
USER_ID=$(id -u)
GROUP_ID=$(id -g)

echo ""
echo "Starting container..."
echo "Press Ctrl+D or type 'exit' to leave the container"
echo "============================================"
echo ""

# Build once; both launchers reuse this development image.
if ! docker image inspect "$IMAGE" > /dev/null 2>&1; then
    echo "Building shared development image: $IMAGE"
    docker build -t "$IMAGE" -f "$SCRIPT_DIR/scripts/Dockerfile" "$SCRIPT_DIR"
fi

CONTAINER_NAME="kokkos-dev-${USER_ID}"

# Check if container is already running
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container '${CONTAINER_NAME}' is already running."
    echo "Attaching to existing container..."
    echo ""
    docker exec -it --user devuser -e HOME="/home/devuser" "$CONTAINER_NAME" bash --login
    exit 0
fi

# Check if container exists but is stopped
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Found stopped container '${CONTAINER_NAME}'. Starting it..."
    docker start "$CONTAINER_NAME"
    docker exec -it --user devuser -e HOME="/home/devuser" "$CONTAINER_NAME" bash --login
    exit 0
fi

echo "Creating new container: ${CONTAINER_NAME}"
echo "User: devuser (UID=${USER_ID}, GID=${GROUP_ID})"
echo ""

# Set up SSH agent permissions if needed
if [ -n "${SSH_AUTH_SOCK}" ] && [ -S "${SSH_AUTH_SOCK}" ]; then
    echo "SSH agent forwarding: enabled"
fi

echo ""
echo "==================================================================="
echo "Container will run in the background."
echo "This shell will attach to it automatically."
echo ""
echo "To stop the container later, run:"
echo "  docker stop ${CONTAINER_NAME}"
echo ""
echo "To remove the container, run:"
echo "  docker rm ${CONTAINER_NAME}"
echo ""
echo "The container will persist across sessions until you remove it."
echo "==================================================================="
echo ""

# Start container as root temporarily to set up the user
docker run -d \
  --name "$CONTAINER_NAME" \
  --ulimit memlock=-1 \
  --gpus all \
  --label "devcontainer.metadata=[{\"remoteUser\":\"devuser\"}]" \
  --label "com.visualstudio.code.devcontainers.user=devuser" \
  -v "$SCRIPT_DIR:$PROJECT_DIR" \
  $SSH_MOUNTS \
  $SSH_ENV \
  -w "$PROJECT_DIR" \
  -h "docker-kokkos-dev" \
  -e USER_ID="$USER_ID" \
  -e GROUP_ID="$GROUP_ID" \
  --entrypoint /bin/bash \
  "$IMAGE" \
  -c "
    # Create group and user with bash shell
    groupadd -g ${GROUP_ID} devgroup 2>/dev/null || true
    useradd -u ${USER_ID} -g ${GROUP_ID} -d /home/devuser -s /bin/bash devuser 2>/dev/null || true
    
    # Set up devuser environment
    if [ ! -f /home/devuser/.bashrc ]; then
      cat > /home/devuser/.bashrc <<'EOFBASHRC'
export PATH=/usr/local/cuda/bin:\${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\${LD_LIBRARY_PATH}
export CUDA_HOME=/usr/local/cuda
if [ -f /etc/bash.bashrc ]; then . /etc/bash.bashrc; fi
export PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
alias ll='ls -alF'; alias la='ls -A'; alias l='ls -CF'
EOFBASHRC
      chown ${USER_ID}:${GROUP_ID} /home/devuser/.bashrc
    fi
    
    # Configure root's bashrc to auto-switch to devuser for interactive shells
    # This ensures docker exec uses devuser by default
    cat >> /root/.bashrc <<EOFROOTBASHRC

# Auto-switch to devuser if running as root in an interactive shell
if [ \\\"\\\$(id -u)\\\" = \\\"0\\\" ] && [ -n \\\"\\\$BASH_VERSION\\\" ] && [ -t 0 ]; then
    export HOME=/home/devuser
    cd ${PROJECT_DIR} 2>/dev/null || cd /home/devuser 2>/dev/null || cd /
    exec gosu devuser bash --login
fi
EOFROOTBASHRC
    
    # Now exec as devuser and sleep infinity
    exec gosu devuser sleep infinity
  "

# Wait a moment for the entrypoint to complete setup
sleep 2

echo "Environment ready!"
echo ""
echo "==================================================================="
echo "Container: ${CONTAINER_NAME}"
echo "User: devuser (UID=${USER_ID}, GID=${GROUP_ID})"
echo "Working directory: $PROJECT_DIR"
echo ""
echo "Available tools:"
echo "  - git, cmake 3.28.3, nvcc (CUDA 13.0.2)"
echo "  - C++ compiler (g++)"
echo "  - nsys (Nsight Systems 2025.6.1) for profiling"
echo ""
echo "Your source files are mounted from the host."
echo ""
echo "The container is running as devuser by default."
echo "VS Code/Cursor will automatically use the correct user and permissions."
echo "All file operations will work correctly."
echo ""
echo "Type 'exit' or press Ctrl+D to leave (container keeps running)."
echo "==================================================================="
echo ""

# Attach to the container (already running as devuser)
docker exec -it --user devuser -e HOME="/home/devuser" "$CONTAINER_NAME" bash --login

echo ""
echo "Exited Docker container."
