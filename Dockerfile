# syntax=docker/dockerfile:1
FROM python:3.11-slim

# Run as a non-root user
RUN useradd --create-home --user-group keepmcp

WORKDIR /app

# Copy dependency metadata first so the install layer is cached
# until pyproject.toml changes
COPY pyproject.toml README.md LICENSE ./

# Copy the application source
COPY src/ ./src/

RUN pip install --no-cache-dir . \
    && chown -R keepmcp:keepmcp /app

USER keepmcp

# Safe default: only notes created by keep-mcp (labelled) may be modified
ENV UNSAFE_MODE="false"

# stdio transport: the MCP client spawns this container and talks over stdin/stdout
CMD ["python", "-m", "server"]
