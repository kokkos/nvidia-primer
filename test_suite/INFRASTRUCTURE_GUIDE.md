<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0
-->

# Kokkos Infrastructure Guide

Guide to local build and test workflows, Docker containers, and version management for the Kokkos NVIDIA GPU Primer.

---

## Docker Container Setup

### Quick Docker Run

#### Interactive Shell

For a development shell with the required tools installed, run the launcher from
the repository root:

```bash
./scripts/run-docker-interactive.sh
```

The launcher above provides the primer's additional build and profiling tools.
To build Kokkos and run the test suite inside that environment, follow
[Local Build and Test Scripts](#local-build-and-test-scripts) below. Set
`KOKKOS_VERSION` to the tag, branch, or commit you want to test.

### Local Build and Test Scripts

From the repository root, build Kokkos and run the test suite in the current environment:

```bash
KOKKOS_VERSION="<tag-branch-or-commit>" ./scripts/build-and-test.sh
```

To install dependencies, build, and run tests in a temporary CUDA container:

```bash
KOKKOS_VERSION="<tag-branch-or-commit>" ./scripts/test-ci-locally.sh
```

Both scripts default to the public Kokkos repository. Set `KOKKOS_REPO_URL` to select another repository and `KOKKOS_VERSION` to select a tag, branch, or commit. The shared Dockerfile downloads x86_64 tools; ARM systems require matching tool packages.

`KOKKOS_VERSION` selects the version for a fresh clone. `build-and-test.sh`
reuses an existing `kokkos/src` checkout; switch it to the intended revision
before rebuilding, or use a fresh working directory for another version.

### Launcher Defaults

Both launchers use the same cached development image, `kokkos-dev-env:latest`.
Each launcher builds it from `scripts/Dockerfile` when the image is missing.
The Dockerfile uses `nvcr.io/nvidia/cuda:13.0.2-devel-ubuntu22.04` and installs
CMake 3.28.3, Nsight Systems 2025.6.1.190, Python 3, and the required profiling
and importer dependencies. Update the shared Dockerfile to
change the base image or tool versions for both launchers.

Both mount the repository at `/tmp/nvidia-primer` and use it as the working
directory. The interactive container persists between sessions; the temporary
test container is removed on exit.

Both launchers reuse the cached image. Rebuild it after changing the Dockerfile,
then recreate any existing interactive container to pick up the new image:

```bash
docker build -t kokkos-dev-env:latest -f scripts/Dockerfile .
```

The interactive launcher reuses its existing container until it is recreated. Files saved in the mounted
repository persist on the host; preserve any needed container-only files before
recreating it.

### GPU Access in Docker

**Requirements:**
- NVIDIA Docker runtime installed
- `--gpus all` flag
- Both launchers set `--ulimit memlock=-1`; GPU profiling also depends on host driver profiling permissions

**Verify GPU Access:** Run inside the development shell opened by the launcher:

```bash
nvidia-smi
```

---

## Version Management

### Tracking Kokkos Versions

#### Using Git Tags

From the repository root, record the tag on the tested Kokkos checkout, then
create the baseline from `test_suite`:

```bash
export KOKKOS_VERSION=$(git -C kokkos/src describe --tags --exact-match)
cd test_suite
./create_all_baselines.sh "$KOKKOS_VERSION"
```

This requires the checkout to be at a tag. Use Git describe or a manual label for
an untagged commit. Do not create a new tag just to name a baseline.

#### Using Git Describe

From the repository root, derive a label from the tested checkout:

```bash
export KOKKOS_VERSION=$(git -C kokkos/src describe --tags --always)
cd test_suite
./create_all_baselines.sh "$KOKKOS_VERSION"
```

#### Manual Version

From `test_suite`, supply a label for the tested version and configuration:

```bash
export KOKKOS_VERSION="<version-and-configuration-label>"
./create_all_baselines.sh "$KOKKOS_VERSION"
```

The script takes a version label, not a directory path, and writes to
`test_suite/baselines/kokkos_<label>`. Compare two captured labels from
`test_suite`:

```bash
./compare_all_baselines.sh "<baseline-label>" "<new-label>"
```

Keep the metadata and text summaries needed for comparisons. Large profiling
reports are excluded from Git and can be removed after analysis.

---

## Troubleshooting

### Docker Issues

#### GPU Not Accessible

**Problem:**
```text
docker: Error response from daemon: could not select device driver "" with capabilities: [[gpu]]
```

**Solution:** Install and configure the NVIDIA Container Toolkit for the Docker
host using the [official installation guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html#configuring-docker),
then retry the launcher. These are host setup steps; they are not needed inside
the development container.

#### Permission Denied

**Problem:**
```text
docker: Got permission denied while trying to connect to the Docker daemon socket
```

**Solution:**
```bash
sudo usermod -aG docker $USER
newgrp docker
```

#### Container Can't See Files

**Problem:**
```text
bash: ./build.sh: No such file or directory
```

**Solution:** Check the launcher's bind mount against
[Launcher Defaults](#launcher-defaults). In the interactive container, verify the
mounted repository and build script:

```bash
cd /tmp/nvidia-primer
ls scripts/build-and-test.sh test_suite/build.sh
```

### Build Issues

#### CMake Cannot Find Kokkos

Point CMake to the installed Kokkos package:

```bash
cmake -S test_suite -B test_suite/build \
  -DKokkos_DIR=/path/to/kokkos/install/lib/cmake/Kokkos
```

#### Build Runs Out of Memory

Limit concurrent compilation jobs for the relevant build directory. Both
launchers use the available CPU count during scripted builds; constrain the
container's CPU allocation on memory-limited machines, or use a manual build
with a smaller parallel count:

```bash
cmake --build test_suite/build --parallel 2
```

#### Disk Space Issues

Inspect the space used by build directories and profiler reports before removing generated files. Keep baseline metadata and summaries needed for comparisons.
