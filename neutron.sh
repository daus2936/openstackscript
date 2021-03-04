#!/bin/bash

source variable.sh

setenforce 0

echo "installing neutron"
dnf -y install openstack-neutron openstack-neutron-ml2 openstack-neutron-openvswitch

echo "set selinux seboolean"
setsebool -P neutron_can_network on 
setsebool -P haproxy_connect_any on 
setsebool -P daemons_enable_cluster_mode on

echo "create user neutron in project service"
openstack user create --domain default --project service --password servicepassword neutron
openstack role add --project service --user neutron admin 

echo "create service neutron"
openstack service create --name neutron --description "OpenStack Networking service" network

echo "create endpoint neutron"
openstack endpoint create --region RegionOne network public http://$IP:9696
openstack endpoint create --region RegionOne network internal http://$IP:9696 
openstack endpoint create --region RegionOne network admin http://$IP:9696

echo "creating database"
mysql <<- EOF
create database neutron_ml2;
grant all privileges on neutron_ml2.* to neutron@'localhost' identified by 'password'; 
grant all privileges on neutron_ml2.* to neutron@'%' identified by 'password'; 
flush privileges;
EOF

echo "configuring /etc/neutron/neutron.conf"
cp /etc/neutron/neutron.conf /root/backup-config/
echo "1" > /etc/neutron/neutron.conf
cat <<- EOF > /etc/neutron/neutron.conf
[DEFAULT]
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
dhcp_agent_notification = True
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
# RabbitMQ connection info
transport_url = rabbit://openstack:password@$IP


# Keystone auth info
[keystone_authtoken]
www_authenticate_uri = http://$IP:5000
auth_url = http://$IP:5000
memcached_servers = $IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = servicepassword

# MariaDB connection info
[database]
connection = mysql+pymysql://neutron:password@$IP/neutron_ml2

# Nova connection info
[nova]
auth_url = http://$IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = servicepassword

[oslo_concurrency]
lock_path = $state_path_neutron/tmp
EOF

echo "configuring /etc/neutron/l3_agent.ini"
sed -i "2i interface_driver = openvswitch" /etc/neutron/l3_agent.ini

echo "configuring /etc/neutron/dhcp_agent.ini"
sed -i "2i interface_driver = openvswitch\ndhcp_driver = neutron.agent.linux.dhcp.Dnsmasq\nenable_isolated_metadata = true " /etc/neutron/dhcp_agent.ini

echo "configuring /etc/neutron/metadata_agent.ini"
sed -i "2i nova_metadata_host = $IP\nmetadata_proxy_shared_secret = metadata_secret" /etc/neutron/metadata_agent.ini
sed -i "s/#memcache_servers = localhost:11211/memcache_servers = $IP:11211/" /etc/neutron/metadata_agent.ini

echo "configuring /etc/neutron/plugins/ml2/ml2_conf.ini"
cat <<EOF >> /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = flat,vlan,gre,vxlan
tenant_network_types = vxlan
mechanism_drivers = openvswitch
extension_drivers = port_security
 
[ml2_type_flat]
flat_networks = $FLAT_NETWORK_NAME

[ml2_type_vxlan]
vni_ranges = 1:1000
EOF

echo "configuring /etc/neutron/plugins/ml2/openvswitch_agent.ini"
cat <<EOF >> /etc/neutron/plugins/ml2/openvswitch_agent.ini
[securitygroup]
firewall_driver = openvswitch
enable_security_group = true
enable_ipset = true

[agent]
tunnel_types = vxlan
prevent_arp_spoofing = True

[ovs]
# specify IP address of this host for [local_ip]
local_ip = $IP
bridge_mappings = $FLAT_NETWORK_NAME:br-$SECOND_INTERFACE
EOF

echo "configuring /etc/nova/nova.conf"
sed -i "2i use_neutron = True\nlinuxnet_interface_driver = nova.network.linux_net.LinuxOVSInterfaceDriver\nfirewall_driver = nova.virt.firewall.NoopFirewallDriver\nvif_plugging_is_fatal = True\nvif_plugging_timeout = 300" /etc/nova/nova.conf

cat <<EOF >> /etc/nova/nova.conf
[neutron]
auth_url = http://$IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = servicepassword
service_metadata_proxy = True
metadata_proxy_shared_secret = metadata_secret
EOF

echo "enable openvswitch"
systemctl enable --now openvswitch
ovs-vsctl add-br br-int 
ovs-vsctl add-br br-$SECOND_INTERFACE
ovs-vsctl add-port br-$SECOND_INTERFACE $SECOND_INTERFACE

ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

echo "Syncing database"
su -s /bin/bash neutron -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugin.ini upgrade head"

echo "enabling and starting neutron services"
systemctl enable --now neutron-dhcp-agent
systemctl enable --now neutron-l3-agent
systemctl enable --now neutron-metadata-agent
systemctl enable --now neutron-openvswitch-agent
systemctl enable --now neutron-server.service

systemctl restart openstack-nova-compute
systemctl restart openstack-nova-api
systemctl restart openstack-nova-conductor
systemctl restart openstack-nova-scheduler
systemctl restart openstack-nova-novncproxy
