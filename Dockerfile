# The generate-api-types scripts require Java.
FROM amazoncorretto:21.0.8 AS java-base

# Production runtime — stable tooling layers first for max caching
FROM oven/bun:1.3.9-slim AS runner

# All system dependencies in a single layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates unzip git tini \
    openssl libcurl4 libssl3 dnsutils iputils-ping file && \
    update-ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# DuckDB CLI + Snowflake driver + Node 20 LTS
# Install DuckDB to a system-wide path (not /root/) so it works with non-root users
ENV DUCKDB_DIR=/opt/duckdb
RUN mkdir -p ${DUCKDB_DIR} && \
    HOME=${DUCKDB_DIR} curl -L https://install.duckdb.org | HOME=${DUCKDB_DIR} bash && \
    cp ${DUCKDB_DIR}/.duckdb/cli/latest/duckdb /usr/local/bin/duckdb && \
    chmod +x /usr/local/bin/duckdb && \
    curl -sSL https://raw.githubusercontent.com/iqea-ai/duckdb-snowflake/main/scripts/install-adbc-driver.sh | bash && \
    ldconfig && \
    duckdb -c "INSTALL snowflake FROM community; LOAD snowflake; SELECT snowflake_version();" || \
    echo "Snowflake verification skipped (offline build)" && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Builder stage
FROM oven/bun:1.3.9-slim AS builder
COPY --from=java-base /usr/lib/jvm /usr/lib/jvm
ENV JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
ENV PATH=$JAVA_HOME/bin:$PATH
ENV NODE_ENV=production
WORKDIR /publisher

# Copy package files first for better layer caching
COPY package.json bun.lock api-doc.yaml ./
COPY packages/server/package.json ./packages/server/package.json
COPY packages/app/package.json ./packages/app/package.json
COPY packages/sdk/package.json ./packages/sdk/package.json

# Install all workspace dependencies once (cached across builds)
RUN bun install

# Build SDK first
COPY packages/sdk/ ./packages/sdk/
WORKDIR /publisher/packages/sdk
RUN bun run build

# Build app
WORKDIR /publisher/packages/app
COPY packages/app/ ./
RUN NODE_OPTIONS='--max-old-space-size=4096' bun run build:server

# Build server
WORKDIR /publisher/packages/server
COPY packages/server/ ./
RUN bun run build:server-only

# Final image — continue from the cached runner base
FROM runner AS final
WORKDIR /publisher

# Copy built artifacts from builder
COPY --from=builder /publisher/package.json /publisher/bun.lock ./
COPY --from=builder /publisher/packages/app/dist/ /publisher/packages/app/dist/
COPY --from=builder /publisher/packages/app/package.json /publisher/packages/app/package.json
COPY --from=builder /publisher/packages/server/dist/ /publisher/packages/server/dist/
COPY --from=builder /publisher/packages/server/package.json /publisher/packages/server/package.json
COPY --from=builder /publisher/packages/sdk/dist/ /publisher/packages/sdk/dist/
COPY --from=builder /publisher/packages/sdk/package.json /publisher/packages/sdk/package.json

# Install production-only deps
RUN bun install --production

# Create non-root user for Cloud Run security best practices
RUN groupadd -r publisher && useradd -r -g publisher -d /home/publisher -s /bin/bash publisher

# Create writable directories for runtime data
# - /tmp is always writable (used for DuckDB temp files)
# - /home/publisher for user home dir (Bun cache, etc.)
# - /publisher/publisher_data for uploaded packages
RUN mkdir -p /etc/publisher /home/publisher /publisher/publisher_data && \
    chown -R publisher:publisher /home/publisher /publisher

# Runtime config
ENV NODE_ENV=production
# Reduce glibc memory arena fragmentation — prevents RSS bloat in constrained environments
ENV MALLOC_ARENA_MAX=2
# Cloud Run injects PORT; entrypoint maps it to PUBLISHER_PORT
ENV PUBLISHER_PORT=4000
# Ensure Bun/Node can find HOME for cache/config
ENV HOME=/home/publisher

# Copy entrypoint script
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER publisher
EXPOSE 4000

# Use tini as PID 1 for proper signal forwarding to Bun
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
CMD ["bun", "run", "--preload", "./packages/server/dist/instrumentation.js", "./packages/server/dist/server.js"]
