#!/bin/bash

source variable.sh

echo "Installing cinder"
dnf install -y openstack-cinder openstack-selinux
setsebool -P virt_use_nfs on

source $ADMIN_USER_FILE

echo "create user cinder in project service"
openstack user create --domain default --project service --password servicepassword cinder
openstack role add --project service --user cinder admin 

echo "create service cinder"
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3

echo "create endpoint cinder, public, internal, admin"
openstack endpoint create --region RegionOne volumev3 public http://$IP:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://$IP:8776/v3/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://$IP:8776/v3/%\(tenant_id\)s

mysql <<- EOF 
create database cinder;
grant all privileges on cinder.* to cinder@'localhost' identified by 'password';
grant all privileges on cinder.* to cinder@'%' identified by 'password';
flush privileges;
EOF

echo "Config /etc/cinder/cinder.conf"
cp /etc/cinder/cinder.conf /root/backup-config/
echo "1" > /etc/cinder/cinder.conf

cat <<- EOF > /etc/cinder/cinder.conf

[DEFAULT]
my_ip = $IP
log_dir = /var/log/cinder
auth_strategy = keystone
transport_url = rabbit://openstack:password@$IP
glance_api_servers = http://$IP:9292
enable_v3_api = True
#enable_v2_api = False
enabled_backends = nfs 

# config cinder-backup (optional)
backup_driver = cinder.backup.drivers.nfs.NFSBackupDriver
backup_mount_point_base = $state_path_cinder/backup_nfs
backup_share = $NFS_IP:$STORAGE_FOR_CINDER_BACKUP

[database]
connection = mysql+pymysql://cinder:password@$IP/cinder


[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = "$IP:11211"
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = servicepassword

[oslo_concurrency]
lock_path = $state_path_cinder/tmp

# line to the end 
[nfs]
volume_driver = cinder.volume.drivers.nfs.NfsDriver
nfs_shares_config = /etc/cinder/nfs_shares
nfs_mount_point_base = $state_path_cinder/mnt
EOF

echo "setting nfs_shares"
cat <<- EOF > /etc/cinder/nfs_shares
$NFS_IP:$STORAGE_FOR_CINDER
EOF

echo "changing nfs_shares owner"
chown .cinder /etc/cinder/nfs_shares

echo "database syncing"
su -s /bin/bash cinder -c "cinder-manage db sync"

echo "add OS_VOLUME_API_VERSION to admin user file"
echo "export OS_VOLUME_API_VERSION=3" >> $ADMIN_USER_FILE

echo "starting and enabling cinder service"
systemctl start openstack-cinder-api
systemctl start openstack-cinder-scheduler
systemctl start openstack-cinder-volume
systemctl enable openstack-cinder-api
systemctl enable openstack-cinder-scheduler
systemctl enable openstack-cinder-volume

