#!/bin/bash

source variable.sh

echo "Installing nfs server"
dnf install nfs-utils 
systemctl start nfs-server.service
systemctl enable nfs-server.service

mkdir $STORAGE_FOR_GLANCE $STORAGE_FOR_CINDER $STORAGE_FOR_CINDER_BACKUP

echo "config /etc/exports"
cat <<- EOF > /etc/exports
$STORAGE_FOR_GLANCE *(rw,sync,no_root_squash)
$STORAGE_FOR_CINDER *(rw,sync,no_root_squash)
$STORAGE_FOR_CINDER_BACKUP *(rw,sync,no_root_squash)
EOF

echo "change chown"
chown -R 161:161 /mnt/glance-inone
chown -R 165:165 /mnt/cinder-inone
chown -R 165:165 /mnt/cinder-backup-inone

echo "disabling firewall and restarting nfs server"
systemctl stop firewalld
systemctl disable firewalld
systemctl restart nfs-server.service




