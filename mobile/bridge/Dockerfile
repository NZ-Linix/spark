# The relay with cloud sessions. Mount a volume at /data and a spark settings.json (your model
# connection) at /config/settings.json.
FROM oven/bun:1.2-debian
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://raw.githubusercontent.com/NZ-Linix/spark/main/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}" \
    PORT=8787 \
    SPARK_RELAY_DATA=/data/relay \
    SPARK_CLOUD_ROOT=/data/cloud \
    SPARK_CLOUD_SETTINGS=/config/settings.json
WORKDIR /app
COPY *.ts package.json ./
EXPOSE 8787
CMD ["bun", "relay.ts"]
