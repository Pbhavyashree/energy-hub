#!/usr/bin/env bash
#
# One-time setup for a fresh Ubuntu 24.04 host (tested target: Oracle Cloud
# Ampere A1, aarch64). Safe to re-run - every step is idempotent.
#
#   curl -fsSL https://raw.githubusercontent.com/Pbhavyashree/energy-hub/main/deploy/server-setup.sh | bash
#
# or, after cloning:
#
#   bash deploy/server-setup.sh
#
# It does NOT create deploy/.env and does NOT start anything. Secrets are
# entered by hand afterwards, so no credential is ever piped through a
# script or left in shell history.

set -euo pipefail

REPO_URL="https://github.com/Pbhavyashree/energy-hub.git"
REPO_DIR="$HOME/energy-hub"

say() { printf '\n=== %s ===\n' "$1"; }

# A script meant to be piped into bash will eventually be piped into the
# wrong bash. Refuse early and say so, rather than part-running against a
# laptop and leaving it in a half-configured state.
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: this provisions the Ubuntu SERVER, not your workstation." >&2
    echo "       Detected: $(uname -s). Run it over ssh on the instance." >&2
    exit 1
fi

# $USER is set by a login shell but not by every environment a piped
# script lands in, and `set -u` turns that into a crash halfway through.
CURRENT_USER="${USER:-$(id -un)}"

# ---------------------------------------------------------------
# 1. Docker
# ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    say "Docker already installed: $(docker --version)"
else
    say "Installing Docker"
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg git

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # dpkg --print-architecture resolves to arm64 on Ampere and amd64 on
    # x86, so this works unchanged on either.
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi

# Lets this user run docker without sudo. Needs a new login to take effect.
if ! id -nG "$CURRENT_USER" | grep -qw docker; then
    say "Adding $CURRENT_USER to the docker group"
    sudo usermod -aG docker "$CURRENT_USER"
    NEEDS_RELOGIN=1
fi

# ---------------------------------------------------------------
# 2. Firewall
# ---------------------------------------------------------------
# Oracle's Ubuntu images ship an iptables INPUT chain that REJECTs
# everything except port 22, and this is SEPARATE from the VCN security
# list in the console. Opening a port in the console alone looks correct
# and still times out, which is the single most common way to lose an
# afternoon on Oracle Cloud.
#
# The rules are inserted at the TOP of INPUT, because appending puts them
# after the REJECT and they would never be reached.
say "Opening ports 8090 and 8093 in iptables"
for port in 8090 8093; do
    if sudo iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        echo "  port $port already open"
    else
        sudo iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
        echo "  opened $port"
    fi
done

# Without persistence these vanish on reboot and the service silently
# becomes unreachable at the worst possible moment.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
sudo netfilter-persistent save

# ---------------------------------------------------------------
# 3. Repository
# ---------------------------------------------------------------
if [ -d "$REPO_DIR/.git" ]; then
    say "Updating existing checkout"
    git -C "$REPO_DIR" pull --ff-only
else
    say "Cloning $REPO_URL"
    git clone "$REPO_URL" "$REPO_DIR"
fi

# ---------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------
cat <<'NEXT'

=== Setup complete ===

Still to do by hand, because these involve secrets:

  1. Create the environment file:

       cd ~/energy-hub/deploy
       cp .env.example .env
       nano .env            # paste the ENTSO-E token, set DB_PASSWORD

     Generate a database password with:
       openssl rand -base64 24

  2. Open the SAME ports in the Oracle console, which is a separate
     firewall from the one configured above:

       Networking > Virtual Cloud Networks > <your VCN>
         > Security Lists > Default Security List
         > Add Ingress Rules

       Source CIDR 0.0.0.0/0, IP Protocol TCP,
       Destination Port Range 8090,8093

  3. Build and start. The first build takes a while - it compiles four
     Maven modules and downloads the Mule runtime:

       cd ~/energy-hub/deploy
       docker compose up -d --build
       docker compose logs -f energy-hub

  4. Verify, from the server and then from your laptop:

       curl -s localhost:8090/api/prc/energy/v1/health
       curl -s localhost:8093/api/exp/home/v1/now

NEXT

if [ "${NEEDS_RELOGIN:-0}" = "1" ]; then
    cat <<'RELOGIN'
NOTE: you were just added to the docker group. Log out and back in
      (exit, then ssh again) before running docker, or every command
      will fail with "permission denied on /var/run/docker.sock".

RELOGIN
fi
