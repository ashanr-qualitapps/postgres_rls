# ---------------------------------------------------------------------------
# Beauty App – PostgreSQL image with RLS support
# Base: postgres:16-alpine  (smaller footprint, production-ready)
# ---------------------------------------------------------------------------
FROM postgres:16-alpine

LABEL maintainer="beauty_app"
LABEL description="PostgreSQL 16 with Row Level Security for beauty_app"

# Install useful extensions available in alpine postgres packages
RUN apk add --no-cache \
      postgresql16-contrib

# Copy custom postgresql configuration
COPY config/postgresql.conf /etc/postgresql/postgresql.conf

# The entrypoint already runs all *.sql / *.sh files found in
# /docker-entrypoint-initdb.d in alphabetical order.
# Our init scripts are mounted via docker-compose.

# Expose standard PostgreSQL port
EXPOSE 5432

# Use our custom config file
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
