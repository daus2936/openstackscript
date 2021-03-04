#!/bin/bash

source variable.sh

setenforce 0

echo "installing nova"
dnf -y install openstack-nova openstack-placement-api 
dnf -y install openstack-nova-compute

semanage port -a -t http_port_t -p tcp 8778
setsebool -P daemons_enable_cluster_mode on
setsebool -P neutron_can_network on

source $ADMIN_USER_FILE
echo "create nova user & rule in project service"
openstack user create --domain default --project service --password servicepassword nova
openstack role add --project service --user nova admin

echo "create user placement in project service"
openstack user create --domain default --project service --password servicepassword placement
openstack role add --project service --user placement admin

echo "create service nova & service placement"
openstack service create --name nova --description "OpenStack Compute service" compute
openstack service create --name placement --description "OpenStack Compute Placement service" placement

echo "Create endpoint nova"
openstack endpoint create --region RegionOne compute public http://$IP:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://$IP:8774/v2.1/%\(tenant_id\)s 
openstack endpoint create --region RegionOne compute admin http://$IP:8774/v2.1/%\(tenant_id\)s

echo "Create endpoint placement"
openstack endpoint create --region RegionOne placement public http://$IP:8778 
openstack endpoint create --region RegionOne placement internal http://$IP:8778
openstack endpoint create --region RegionOne placement admin http://$IP:8778

echo "create database nova, nova_api, nova_cell0, placement"
mysql <<- EOF
create database nova;
grant all privileges on nova.* to nova@'localhost' identified by 'password';
grant all privileges on nova.* to nova@'%' identified by 'password';
create database nova_api; 
grant all privileges on nova_api.* to nova@'localhost' identified by 'password';
grant all privileges on nova_api.* to nova@'%' identified by 'password';
create database placement;
grant all privileges on placement.* to placement@'localhost' identified by 'password'; 
grant all privileges on placement.* to placement@'%' identified by 'password';
flush privileges;
EOF

echo "config /etc/nova/nova.conf"
cp /etc/nova/nova.conf /root/backup-config
echo "1" > /etc/nova/nova.conf
cat <<- EOF > /etc/nova/nova.conf
[DEFAULT]
# define own IP address
my_ip = $IP
enabled_apis = osapi_compute,metadata
log_dir = /var/log/nova
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$IP

[api]
auth_strategy = keystone

# Glance connection info
[glance]
api_servers = http://$IP:9292

[cinder]
os_region_name = RegionOne

[oslo_concurrency]
lock_path = $state_path_nova/tmp

# MariaDB connection info
[api_database]
connection = mysql+pymysql://nova:password@$IP/nova_api

[database]
connection = mysql+pymysql://nova:password@$IP/nova

# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = servicepassword

[placement]
auth_url = http://$IP:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

echo "config /etc/placement/placement.conf"
cp /etc/placement/placement.conf /root/backup-config
echo "1" > /etc/placement/placement.conf
cat <<- EOF > /etc/placement/placement.conf
[DEFAULT]
debug = false

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = servicepassword

[placement_database]
connection = mysql+pymysql://placement:password@$IP/placement
EOF

echo "Setting /etc/httpd/conf.d/00-placement-api.conf"
sed -i "16i \ \ <Directory /usr/bin>\n    Require all granted\n  </Directory>" /etc/httpd/conf.d/00-placement-api.conf

echo "Syncing database"
su -s /bin/bash placement -c "placement-manage db sync" 
su -s /bin/bash nova -c "nova-manage api_db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 map_cell0" 
su -s /bin/bash nova -c "nova-manage db sync"
su -s /bin/bash nova -c "nova-manage cell_v2 create_cell --name cell1"
su -s /bin/bash nova -c "nova-manage cell_v2 list_cells"

nova-manage cell_v2 discover_hosts --verbose

systemctl restart httpd 

cat <<- EOF > /var/log/placement/placement-api.log

EOF

echo "change ownership"
chown placement:root /var/log/placement
chown placement. /var/log/placement/placement-api.log

echo "enabling nova services"
systemctl enable --now openstack-nova-api
systemctl enable --now openstack-nova-conductor
systemctl enable --now openstack-nova-scheduler
systemctl enable --now openstack-nova-novncproxy

echo "configuring /etc/nova/nova.conf"
cat <<EOF >> /etc/nova/nova.conf
[vnc]
enabled = True
server_listen = 0.0.0.0
server_proxyclient_address = $IP
novncproxy_base_url = http://$IP:6080/vnc_auto.html
EOF

echo "starting nova services"
systemctl enable --now openstack-nova-compute 
systemctl restart openstack-nova-api
systemctl restart openstack-nova-conductor
systemctl restart openstack-nova-scheduler
systemctl restart openstack-nova-novncproxy

su -s /bin/bash nova -c "nova-manage cell_v2 discover_hosts"


