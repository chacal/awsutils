#!/bin/sh
#
# Script to initialize an Amazon instance as an OpenVPN server.
# 
# Usage:
# 1) Create a VPC with internet GW & subnet (use address range set in PRIVATE_NETWORK & PRIVATE_NETMASK)
# 2) Create a Security Group and allow incoming traffic to TCP/80 (OpenVPN by default) & TCP/443 (Apache)
# 3) Change USERNAME & PASSWORD below. These credentials are used to download OpenVPN client key & certs via HTTPS.
# 4) Launch new instance into the VPC. Use Ubuntu Server 12.04 AMI. Copy/paste this file as User Data for the instance.
# 5) Create new Elastic IP and associate it with the launched instance. This IP is VPN server's public address to which clients will connect.
# 6) Set instance's source/destination check to false (this allows VPN server to NAT traffic to internet)
# 7) Wait for the instance to launch and go to https://<INSTANCE_PUBLIC_ADDRESS/ Authenticate with USERNAME & PASSWORD.
# 8) Download ca.crt, client.crt and client.key
# 9) Setup VPN client to connect to server's public address using TCP and downloaded certs & key file
# 10) Optionally download client.conf and use it to set up the client (openvpn client.conf)
# 11) Profit!

USERNAME=username
PASSWORD=password

PRIVATE_IP=`wget -q -O - 'http://169.254.169.254/latest/meta-data/local-ipv4'`
PUBLIC_IP=`wget -q -O - 'http://169.254.169.254/latest/meta-data/public-ipv4'`

PRIVATE_NETWORK=10.0.0.0
PRIVATE_NETMASK=255.255.0.0
VPN_NETWORK=10.0.100.0
VPN_NETMASK=255.255.255.0

VPN_SERVER_PORT=80

while [ -z "$PUBLIC_IP" ]
do 
  echo "Waiting for public IP"
  PUBLIC_IP=`wget -q -O - 'http://169.254.169.254/latest/meta-data/public-ipv4'`
  sleep 1
done


apt-get install -y openvpn apache2

cat > /etc/apache2/sites-available/authenticated-ssl <<EOF
<IfModule mod_ssl.c>
<VirtualHost _default_:443>
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www
        <Directory />
                Options FollowSymLinks
                AllowOverride None
        </Directory>
        <Directory /var/www/>
                Options Indexes FollowSymLinks MultiViews
                AllowOverride None
                AuthType Basic
                AuthName "Use \$USERNAME & \$PASSWORD from user data to log in"
                AuthUserFile /etc/apache2/htpasswd
                Require valid-user              
                Order allow,deny
                allow from all
        </Directory>
        SSLEngine on
        SSLCertificateFile    /etc/ssl/certs/ssl-cert-snakeoil.pem
        SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
</VirtualHost>
</IfModule>
EOF

htpasswd -c -b /etc/apache2/htpasswd $USERNAME $PASSWORD
chmod 600 /etc/apache2/htpasswd
chown www-data:www-data /etc/apache2/htpasswd
a2enmod ssl
a2ensite authenticated-ssl
a2dissite default
rm /var/www/index.html

sed -i '/Listen 80/s/^/#/g' /etc/apache2/ports.conf
sed -i '/NameVirtualHost \*:80/s/^/#/g' /etc/apache2/ports.conf

service apache2 restart

cp -r /usr/share/doc/openvpn/examples/easy-rsa/2.0 /root/easy-rsa
cp /usr/share/doc/openvpn/examples/easy-rsa/2.0/openssl-1.0.0.cnf /root/easy-rsa/openssl.cnf

cd /root/easy-rsa
. ./vars
./clean-all
./pkitool --initca
./pkitool --server server
KEY_CN=client ./pkitool
./build-dh

cp /root/easy-rsa/keys/ca.crt /etc/openvpn
cp /root/easy-rsa/keys/dh1024.pem /etc/openvpn
cp /root/easy-rsa/keys/server.crt /etc/openvpn
cp /root/easy-rsa/keys/server.key /etc/openvpn
cp /root/easy-rsa/keys/ca.crt /root/easy-rsa/keys/client.key /root/easy-rsa/keys/client.crt /var/www
chown www-data:www-data /var/www/*
rm -r /root/easy-rsa

cat > /etc/openvpn/server.conf <<EOF
port $VPN_SERVER_PORT
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh1024.pem
server $VPN_NETWORK $VPN_NETMASK
push "route $PRIVATE_NETWORK $PRIVATE_NETMASK"
;push "dhcp-option DNS 8.8.8.8"
duplicate-cn
keepalive 10 120
comp-lzo
user nobody
group nogroup
persist-key
persist-tun
verb 3
EOF

service openvpn restart

cat > /var/www/client.conf <<EOF
client
dev tun
proto tcp
remote $PUBLIC_IP $VPN_SERVER_PORT
resolv-retry infinite
nobind
persist-key
persist-tun
ca ca.crt
cert client.crt
key client.key
ns-cert-type server
comp-lzo
EOF


iptables -t nat -A POSTROUTING -s ${VPN_NETWORK}/${VPN_NETMASK} -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s ${PRIVATE_NETWORK}/${PRIVATE_NETMASK} -o eth0 -j MASQUERADE
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables-save > /etc/iptables.rules
cat > /etc/network/if-pre-up.d/iptablesload <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
echo 1 > /proc/sys/net/ipv4/ip_forward
exit 0
EOF
