# Test runner with the tools the scripts expect on a typical Debian server.
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash tar gzip gnupg mariadb-client awscli ca-certificates util-linux findutils coreutils \
 && rm -rf /var/lib/apt/lists/*
