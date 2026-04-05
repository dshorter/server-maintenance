#!/bin/bash

BACKUP_DIR="/root/n8n-data/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "?? Starting backup at $TIMESTAMP"

# Create backup directory if it doesn't exist
mkdir -p $BACKUP_DIR

# Backup n8n workflows
docker exec n8n n8n export:workflow --all --output=/data/backups/workflows_$TIMESTAMP.json

# Backup transaction data
if [ -d "/root/n8n-data/transactions" ]; then
    tar -czf $BACKUP_DIR/transactions_$TIMESTAMP.tar.gz -C /root/n8n-data transactions/
fi

# Backup n8n database
if [ -f "/root/n8n-data/database.sqlite" ]; then
    cp /root/n8n-data/database.sqlite $BACKUP_DIR/database_$TIMESTAMP.sqlite
fi

# Keep only last 7 days of backups
find $BACKUP_DIR -type f -mtime +7 -delete

echo "? Backup completed: $TIMESTAMP"
ls -lh $BACKUP_DIR | tail -5