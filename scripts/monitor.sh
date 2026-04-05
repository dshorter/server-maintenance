#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Check if n8n is running
if docker ps | grep -q n8n; then
    echo -e "${GREEN}? n8n is running${NC}"
    
    # Show resource usage
    docker stats --no-stream n8n
    
    # Check disk usage
    echo -e "\n?? Disk Usage:"
    df -h | grep -E '^/dev/'
    
    # Check recent logs for errors
    ERROR_COUNT=$(docker logs n8n --since=1h 2>&1 | grep -c ERROR)
    if [ $ERROR_COUNT -gt 0 ]; then
        echo -e "${RED}?? Found $ERROR_COUNT errors in last hour${NC}"
    fi
else
    echo -e "${RED}? n8n is down! Attempting restart...${NC}"
    cd /opt/ai-agent-platform
    docker compose up -d
    
    # Send alert (optional - configure your notification method)
    # curl -X POST https://api.pushover.net/1/messages.json \
    #   -d "token=YOUR_APP_TOKEN" \
    #   -d "user=YOUR_USER_KEY" \
    #   -d "message=n8n was down and has been restarted"
fi