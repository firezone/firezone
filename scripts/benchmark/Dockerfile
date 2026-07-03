# Benchmark image: locally-built release binary on top of the CI-built debug
# image (which bundles iperf3, iproute2, ethtool etc.). Mirrors how CI builds
# the `perf/*` images ("release binaries inside debug stage images") without
# needing to run `apk` during the build.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG PACKAGE
ARG INIT_SCRIPT
COPY ${PACKAGE} /bin/${PACKAGE}
COPY ${INIT_SCRIPT} /bin/docker-init.sh
