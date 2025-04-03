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
    rsync \
    ca-certificates

# Create non-root user for better security
RUN addgroup -S uds && adduser -S uds -G uds

# Create UDS directory structure
RUN mkdir -p /opt/uds/scripts /opt/uds/plugins /opt/uds/configs /opt/uds/logs /opt/uds/certs /opt/uds/www

# Copy UDS files into the image
COPY scripts/ /opt/uds/scripts/
COPY plugins/ /opt/uds/plugins/

# Make scripts executable
RUN find /opt/uds/scripts -name "*.sh" -exec chmod +x {} \; && \
    find /opt/uds/plugins -name "*.sh" -exec chmod +x {} \; && \
    chown -R uds:uds /opt/uds

# Create entrypoint script
COPY action/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Use non-root user
USER uds
WORKDIR /opt/uds

ENTRYPOINT ["/entrypoint.sh"]