#!/bin/bash

source variable.sh
echo "Installing Glance"
dnf -y install openstack-glance
setsebool -P glance_api_can_network on 

echo "Create Glance User"
source $ADMIN_USER_FILE
openstack project create --domain default --description "Service Project" service
openstack user create --domain default --project service --password servicepassword glance
openstack role add --project service --user glance admin


echo "Create Glance Service"
openstack service create --name glance --description "OpenStack Image service" image

echo "Creating glance endpoint"
openstack endpoint create --region RegionOne image public http://$IP:9292 
openstack endpoint create --region RegionOne image internal http://$IP:9292
openstack endpoint create --region RegionOne image admin http://$IP:9292

echo "Creating glance database and glance user database"
mysql <<- EOF
create database glance; 
grant all privileges on glance.* to glance@'localhost' identified by 'password';
grant all privileges on glance.* to glance@'%' identified by 'password';
flush privileges;
EOF

echo "Setting glance-api.conf"
mkdir /root/backup-config
cp /etc/glance/glance-api.conf /root/backup-config
echo "1" > /etc/glance/glance-api.conf
cat <<- EOF > /etc/glance/glance-api.conf
[DEFAULT]
bind_host = 0.0.0.0

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = $GLANCE_STORAGE

[database]
# MariaDB connection info
connection = mysql+pymysql://glance:password@$IP/glance

# keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = servicepassword

[paste_deploy]
flavor = keystone
EOF

echo "Config /etc/fstab"
cat <<EOF >> /etc/fstab
$NFS_IP:$STORAGE_FOR_GLANCE  $GLANCE_STORAGE  nfs  _netdev,defaults 0 0
EOF

echo "Mounting NFS"
showmount -e $NFS_IP
mkdir $GLANCE_STORAGE
mount -av

echo "Sync Database"
su -s /bin/bash glance -c "glance-manage db_sync"

echo "Starting the glance service"
chown -R glance:glance $GLANCE_STORAGE
systemctl start openstack-glance-api
systemctl enable openstack-glance-api
systemctl restart openstack-glance-api


