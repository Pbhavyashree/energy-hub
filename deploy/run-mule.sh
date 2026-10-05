#!/usr/bin/env bash
#
# Start the Mule CE runtime WITHOUT the Tanuki service wrapper.
#
# WHY THIS EXISTS
#
# bin/mule launches through the Tanuki Java Service Wrapper, which ships
# NATIVE binaries per platform. The 4.6.0 distribution contains:
#
#   exec/wrapper-linux-x86-64   exec/wrapper-linux-x86-32
#   exec/wrapper-linux-ia-64    exec/wrapper-linux-ppc-64
#   exec/wrapper-solaris-*      exec/wrapper-macosx-ppc-32
#
# There is no aarch64 build - it bundles Tanuki 3.2.3, which predates ARM
# servers. So bin/mule cannot start on an ARM host, which is most of the
# free compute available anywhere (Oracle Ampere, AWS Graviton).
#
# HOW THIS WORKS
#
# Mule 4.6 treats the wrapper as a pluggable implementation. wrapper.conf
# sets it explicitly:
#
#   -Dmule.bootstrap.container.wrapper.class=
#       org.mule.runtime.module.boot.tanuki.internal.MuleContainerTanukiWrapper
#
# MuleContainerWrapperProvider reads that property, loads the class
# reflectively, and checks it implements MuleContainerWrapper. There is NO
# default - the property is mandatory, and any conforming implementation is
# accepted. The stock distribution ships a second one:
#
#   org.mule.runtime.module.boot.internal.MuleContainerBasicWrapper
#
# It is pure Java, and org.mule.boot.api exports the internal package to
# org.mule.boot, so it is reachable from the entry point. Selecting it
# removes the only architecture-dependent component in the boot path.
#
# The tanuki MODULE still has to resolve, because JpmsUtils validates that
# it is present in --add-modules. That is fine: resolving a module loads no
# native code. The .so is only touched if the Tanuki wrapper is actually
# instantiated, which it now never is.
#
# This is also a better container entry point than bin/mule regardless of
# architecture. Docker already supervises and restarts the process, so a
# process supervisor inside the container is a second thing doing the same
# job - and it swallows signals, which is why containers wrapped this way
# are slow to stop.
#
# USAGE
#
#   MULE_HOME=/opt/mule ./run-mule.sh
#
# Secrets come from the environment and are passed as system properties,
# the same way wrapper.conf supplies them locally. Nothing is read from a
# file in the repository.

set -euo pipefail

MULE_HOME="${MULE_HOME:-/opt/mule}"

# Git Bash on Windows hands bash a POSIX path, but the JVM is a native
# Windows process and needs a Windows one. Harmless no-op on Linux.
if command -v cygpath >/dev/null 2>&1; then
    MULE_HOME="$(cygpath -m "$MULE_HOME")"
fi

if [ ! -d "$MULE_HOME/lib/boot" ]; then
    echo "ERROR: no Mule runtime at $MULE_HOME (lib/boot not found)." >&2
    exit 1
fi

# ---------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------
# Taken from the environment. For a LOCAL test there may be no environment
# variable set, so fall back to reading the value already configured in
# wrapper.conf - which keeps the token out of the shell history and out of
# this script.
if [ -z "${ENTSOE_TOKEN:-}" ] && [ -f "$MULE_HOME/conf/wrapper.conf" ]; then
    ENTSOE_TOKEN="$(sed -n 's/.*-Dentsoe\.token=//p' "$MULE_HOME/conf/wrapper.conf" \
                    | tr -d '\r' | head -1)"
fi

if [ -z "${ENTSOE_TOKEN:-}" ]; then
    echo "ERROR: ENTSOE_TOKEN is not set and none was found in wrapper.conf." >&2
    exit 1
fi

DB_URL="${DB_URL:-jdbc:postgresql://localhost:5432/energyhub}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-postgres}"

# ---------------------------------------------------------------
# JPMS flags
# ---------------------------------------------------------------
# These are not optional and not guesswork: they are compiled into
# JpmsUtils as REQUIRED_ADD_MODULES, REQUIRED_ADD_OPENS_JAVA_LANG and
# REQUIRED_ADD_OPENS_JAVA_LANG_REFLECT, and validateNoBootModuleLayerTweaking()
# fails the boot if they are missing.
JPMS_FLAGS=(
    --module-path "$MULE_HOME/lib/boot"
    --add-modules=java.se,org.mule.boot.tanuki,org.mule.runtime.jpms.utils,com.fasterxml.jackson.core
    --add-opens=java.base/java.lang=org.mule.runtime.jpms.utils
    --add-opens=java.base/java.lang.reflect=org.mule.runtime.jpms.utils
)

# ---------------------------------------------------------------
# JVM tuning, carried over from wrapper.conf
# ---------------------------------------------------------------
# MaxMetaspaceSize is 512m rather than the shipped 256m because four
# applications in one runtime exhausted the default during repeated
# redeploys - see NOTES.md.
JVM_OPTS=(
    -Xms"${MULE_HEAP:-1024}m"
    -Xmx"${MULE_HEAP:-1024}m"
    -XX:MetaspaceSize=128m
    -XX:MaxMetaspaceSize="${MULE_METASPACE:-512}m"
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:NewRatio=1
    -XX:MaxTenuringThreshold=8
)

MULE_PROPS=(
    -Dmule.home="$MULE_HOME"
    -Dmule.base="$MULE_HOME"
    -Dmule.bootstrap.container.wrapper.class=org.mule.runtime.module.boot.internal.MuleContainerBasicWrapper
    -Dorg.quartz.scheduler.skipUpdateCheck=true
    -Djava.locale.providers=COMPAT,CLDR,SPI
    -Dlog4j2.disable.jmx=true
    -Dmule.metadata.cache.entryTtl.minutes=10
    -Dmule.metadata.cache.expirationInterval.millis=5000
    -Dfile.encoding=UTF-8
)

APP_PROPS=(
    -Dentsoe.token="$ENTSOE_TOKEN"
    -Ddb.url="$DB_URL"
    -Ddb.user="$DB_USER"
    -Ddb.password="$DB_PASSWORD"
    # Alerting is off unless explicitly enabled, so a local run never
    # messages anyone by accident while testing the poll.
    -Dalert.negativeEnabled="${ALERT_NEGATIVE_ENABLED:-false}"
    -Dalert.telegramToken="${TELEGRAM_TOKEN:-unset}"
    -Dalert.telegramChatId="${TELEGRAM_CHAT_ID:-unset}"
)

echo "Starting Mule from $MULE_HOME without the Tanuki wrapper"
echo "  heap=${MULE_HEAP:-1024}m metaspace=${MULE_METASPACE:-512}m"
echo "  db=$DB_URL"

# exec, so the JVM becomes PID 1 in a container and receives SIGTERM
# directly. Without it the shell is PID 1, signals are not forwarded, and
# every stop waits for Docker's ten second timeout before a kill.
exec java \
    "${JPMS_FLAGS[@]}" \
    "${JVM_OPTS[@]}" \
    "${MULE_PROPS[@]}" \
    "${APP_PROPS[@]}" \
    -m org.mule.boot/org.mule.runtime.module.reboot.MuleContainerBootstrap
