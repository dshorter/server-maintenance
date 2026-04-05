#!/bin/bash

echo "?? Deploying AI Agent Platform..."
echo "?? $(date)"

# Navigate to project directory
cd /opt/ai-agent-platform || exit 1

# Pull latest changes
echo "?? Pulling latest changes..."
git pull origin main

# Stop existing containers
echo "?? Stopping containers..."
docker compose down

# Pull latest images
echo "?? Updating Docker images..."
docker compose pull

# Start containers
echo "?? Starting containers..."
docker compose up -d

# Wait for health check
echo "? Waiting for services to be healthy..."
sleep 10

# Show status
echo "?? Current status:"
docker compose ps

echo "? Deployment complete!"
echo "?? View logs with: docker compose logs -f"