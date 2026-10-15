# syntax=docker/dockerfile:1
#
# Bakes a private/proxy CA bundle into the n8n task-runner sidecar image so
# the JavaScript runner process can trust it. Build
# from the exact runner tag your n8n deployment is running:
#
#   kubectl -n <n8n_kube_namespace> get deploy n8n-worker \
#     -o jsonpath='{..image}'
#
# then:
#
#   docker build \
#     --build-arg RUNNER_IMAGE_TAG=2.41.4 \
#     --build-arg CA_BUNDLE=ca-bundle.pem \
#     -t <your-registry>/<repo>/runners:2.41.4-ca-v1 .
#   docker push <your-registry>/<repo>/runners:2.41.4-ca-v1
#
# See README.md for the daemonless `crane` alternative used to build and
# test this reference, and for why the tag suffix (`-ca-v1`, `-ca-v2`, ...)
# must change on every CA rotation.

ARG RUNNER_IMAGE_TAG=2.41.4
FROM n8nio/runners:${RUNNER_IMAGE_TAG}

# PEM file (one or more certificates) to add to the image. Node's
# NODE_EXTRA_CA_CERTS *adds* to the platform trust store, so this file only
# needs your private/proxy CA certificate(s), not a full bundle.
ARG CA_BUNDLE=ca-bundle.pem

# The base image's default USER is the non-root "runner" account (uid 1000).
# Switch to root to copy the file in as a world-readable, root-owned file,
# then switch back so the runtime user is unchanged.
USER root
COPY ${CA_BUNDLE} /opt/n8n-custom-ca/ca.pem
RUN chmod 0644 /opt/n8n-custom-ca/ca.pem
USER runner
