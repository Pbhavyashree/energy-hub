# syntax=docker/dockerfile:1
#
# energy-hub: all four Mule applications in one CE runtime.
#
# Built FROM SOURCE rather than from prebuilt jars, so the image is
# reproducible from a git checkout alone and CI has nothing to hand it.
#
# Architecture-independent on purpose. The stock bin/mule launcher is not -
# it runs through the Tanuki wrapper, whose native binaries stop at x86 -
# so this image starts the runtime through deploy/run-mule.sh instead,
# which selects Mule's own pure-Java MuleContainerBasicWrapper. See
# NOTES.md. That is what makes free ARM hosting (Oracle Ampere, AWS
# Graviton) usable at all.

# ---------------------------------------------------------------
# Build
# ---------------------------------------------------------------
FROM maven:3.9-eclipse-temurin-17 AS build

WORKDIR /src

# shared-specs first: every module's maven-resources-plugin copies the
# canonical RAML library out of it at generate-resources.
COPY shared-specs ./shared-specs
COPY sys-api-awattar ./sys-api-awattar
COPY sys-api-entsoe  ./sys-api-entsoe
COPY process-api     ./process-api
COPY exp-api-home    ./exp-api-home

# Tests are skipped HERE and run in CI instead. A container build is not
# the place to discover a test failure, and MUnit boots a Mule runtime per
# suite, which doubles the build for no added signal.
RUN --mount=type=cache,target=/root/.m2 \
    set -eu; \
    for module in sys-api-awattar sys-api-entsoe process-api exp-api-home; do \
        echo "=== building $module ==="; \
        mvn -B --no-transfer-progress -f "$module/pom.xml" clean package -DskipTests; \
    done; \
    mkdir -p /out; \
    cp */target/*-mule-application.jar /out/; \
    ls -la /out

# ---------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------
FROM eclipse-temurin:17-jre-jammy AS runtime

ARG MULE_VERSION=4.6.0
ENV MULE_HOME=/opt/mule

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    curl -fsSL -o /tmp/mule.tar.gz \
      "https://repository.mulesoft.org/nexus/content/repositories/releases/org/mule/distributions/mule-standalone/${MULE_VERSION}/mule-standalone-${MULE_VERSION}.tar.gz"; \
    tar -xzf /tmp/mule.tar.gz -C /opt; \
    mv "/opt/mule-standalone-${MULE_VERSION}" "${MULE_HOME}"; \
    rm /tmp/mule.tar.gz; \
    rm -rf "${MULE_HOME}"/apps/* "${MULE_HOME}"/logs/*

# The x86 wrapper binaries under lib/boot/exec stay where they are. They
# are never executed - run-mule.sh selects the pure-Java wrapper - but the
# org.mule.boot.tanuki MODULE must still resolve, because JpmsUtils
# validates it is present in --add-modules. Resolving a module loads no
# native code; deleting the jar would break the boot, deleting the
# binaries would only save a megabyte.

COPY --from=build /out/*.jar          ${MULE_HOME}/apps/
COPY deploy/run-mule.sh               /usr/local/bin/run-mule.sh

RUN chmod +x /usr/local/bin/run-mule.sh \
 && groupadd --system mule \
 && useradd --system --gid mule --home "${MULE_HOME}" mule \
 && chown -R mule:mule "${MULE_HOME}"

USER mule
WORKDIR ${MULE_HOME}

# 8090 process, 8093 experience. 8091 and 8092 are the system APIs and are
# deliberately NOT exposed here - nothing outside this container should
# reach an upstream adapter directly. docker-compose publishes only what
# belongs on the internet.
EXPOSE 8090 8093

# start-period is generous because four applications each parse a RAML at
# boot, and AMF parsing is the slow part. Marking the container unhealthy
# while it is still legitimately starting would restart-loop it forever.
HEALTHCHECK --interval=30s --timeout=5s --start-period=240s --retries=3 \
    CMD curl -fsS http://localhost:8090/api/prc/energy/v1/health || exit 1

ENTRYPOINT ["/usr/local/bin/run-mule.sh"]
