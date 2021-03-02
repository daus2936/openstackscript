#!/bin/bash

yum -y install centos-release-openstack-ussuri
yum -y install epel-release

echo "INSTALL MARIADB"
yum -y install mariadb-server
cat <<- EOF > /etc/my.cnf
[client-server]

!includedir /etc/my.cnf.d

[mysqld]
max_connections=8192
EOF

systemctl restart mariadb
systemctl enable mariadb

mysql_secure_installation <<EOF

n
y
n
y
y
EOF

systemctl restart mariadb

echo "INSTALL MEMCHACHED"

yum -y install memcached
cat <<- EOF > /etc/sysconfig/memcached
PORT="11211"
USER="memcached"
MAXCONN="1024"
CACHESIZE="64"
OPTIONS="-l 0.0.0.0,::"
EOF

systemctl restart memcached
systemctl enable memcached
systemctl start memcached.service
systemctl enable memcached.service

yum -y install rabbitmq-server
systemctl start rabbitmq-server.service
systemctl enable rabbitmq-server.service
rabbitmqctl add_user openstack password
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
