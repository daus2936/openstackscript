#!/bin/bash

source variable.sh

echo "Starting installation of Keystone"
dnf config-manager --set-enabled powertools
dnf --enablerepo=powertools install fontawesome-fonts-web
yum -y install openstack-keystone python3-openstackclient httpd mod_ssl python3-mod_wsgi python3-oauth2client
setsebool -P httpd_use_openstack on 
setsebool -P httpd_can_network_connect on
setsebool -P httpd_can_network_connect_db on

mysql <<- EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$KEYSTONE_DBPASS';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$KEYSTONE_DBPASS';
flush privileges;
EOF

sed -i "s/#memcache_servers = localhost:11211/memcache_servers = $IP:11211/" /etc/keystone/keystone.conf
sed -i "s|#connection = <None>|connection = mysql+pymysql://keystone:password@$IP/keystone|" /etc/keystone/keystone.conf
sed -i "s/#provider = fernet/provider = fernet/" /etc/keystone/keystone.conf

echo "Sync with database"
su -s /bin/bash keystone -c "keystone-manage db_sync"

echo "Keystone-manage,initialize key"
cd /etc/keystone/
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

echo "Bootstrap Keystone"

keystone-manage bootstrap --bootstrap-password $ADMIN_PASS \
--bootstrap-admin-url http://$IP:5000/v3/ \
--bootstrap-internal-url http://$IP:5000/v3/ \
--bootstrap-public-url http://$IP:5000/v3/ \
--bootstrap-region-id RegionOne

echo "Configure "
ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/

systemctl start httpd
systemctl enable httpd

cat <<- EOF > $ADMIN_USER_FILE
#!/bin/sh
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://$IP:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
export PS1='[\u@\h \W(keystone)]\$ '
EOF

echo "INSTALLING HORIZON"
yum -y update
dnf -y install openstack-dashboard


sed -i '39d' /etc/openstack-dashboard/local_settings

sed -i "39i ALLOWED_HOSTS = ['*', ]" /etc/openstack-dashboard/local_settings

cat <<EOF >> /etc/openstack-dashboard/local_settings
CACHES = {
    'default': {
        'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
        'LOCATION': '$IP:11211',
    },
}
EOF

sed -i "s/#SESSION_ENGINE = 'django.contrib.sessions.backends.signed_cookies'/SESSION_ENGINE = 'django.contrib.sessions.backends.cache'/" /etc/openstack-dashboard/local_settings

sed -i -e 's/OPENSTACK_HOST = "127.0.0.1"/OPENSTACK_HOST = "'"$IP"'"/g' /etc/openstack-dashboard/local_settings

sed -i -e 's|OPENSTACK_KEYSTONE_URL = "http://%s/identity/v3" % OPENSTACK_HOST|OPENSTACK_KEYSTONE_URL = "'"http://$IP:5000/v3"'"|g' /etc/openstack-dashboard/local_settings

sed -i 's|TIME_ZONE = "UTC"|TIME_ZONE = "Asia/Jakarta"|' /etc/openstack-dashboard/local_settings

cat <<EOF >> /etc/openstack-dashboard/local_settings
WEBROOT = '/dashboard/'
LOGIN_URL = '/dashboard/auth/login/'
LOGOUT_URL = '/dashboard/auth/logout/'
LOGIN_REDIRECT_URL = '/dashboard/'
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'Default'
OPENSTACK_API_VERSIONS = {
  "identity": 3,
  "volume": 3,
  "compute": 2,
}
EOF


sed -i "4i WSGIApplicationGroup %{GLOBAL}" /etc/httpd/conf.d/openstack-dashboard.conf

systemctl restart httpd