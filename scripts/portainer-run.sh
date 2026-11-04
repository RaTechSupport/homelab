#!/usr/bin/env bash
# Portainer is NOT a Portainer stack: it was started once with `docker run`.
# Reconstructed from `docker inspect portainer` on 2026-10-20 (image, restart policy, ports, mounts, no custom cmd).
# Use to recreate it (e.g. after a rebuild). Data/settings/stacks live in the backed-up volume portainer_data.
# Excluded from Watchtower (WATCHTOWER_DISABLE_CONTAINERS=portainer) -> update by hand:
#   docker pull portainer/portainer-ce:latest && docker stop portainer && docker rm portainer && <run command below>
docker run -d \
  --name portainer \
  --restart=always \
  -p 8000:8000 \
  -p 9000:9000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
