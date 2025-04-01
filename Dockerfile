FROM alpine:3.18

# Install required packages
RUN apk add --no-cache \
    bash \
    curl \
    docker-cli \
    git \
    jq \
    openssh-client \
    openssl \
    rsync

# Create non-root user for better security
RUN addgroup -S uds && adduser -S uds -G uds

# Copy UDS files into the image
COPY scripts/ /opt/uds/scripts/
COPY plugins/ /opt/uds/plugins/

# Make scripts executable
RUN chmod +x /opt/uds/scripts/*.sh

# Create directories for configs and logs
RUN mkdir -p /opt/uds/configs /opt/uds/logs /opt/uds/certs && \
    chown -R uds:uds /opt/uds

# Create entrypoint script
COPY action/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Use non-root user
USER uds
WORKDIR /opt/uds

ENTRYPOINT ["/entrypoint.sh"]
