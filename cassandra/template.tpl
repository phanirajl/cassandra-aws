#!/bin/bash
# Author: Alejandro Galue <agalue@opennms.org>
# Warning: This is intended to be used through Terraform's template plugin only

# AWS Template Variables
# - cluster_name = ${cluster_name}
# - datacenter = ${datacenter}
# - rack = ${rack}
# - seed_name = ${seed_name}
# - private_ips = ${private_ips}
# - heap_size = ${heap_size}
# - startup_delay = ${startup_delay}
# - device_names = ${device_names}

IFS=',' read -r -a ip_list <<< "${private_ips}"
IFS=',' read -r -a device_list <<< "${device_names}"

num_instances=$${#ip_list[@]}

echo "### Configuring $num_instances Cassandra instances using the following IP Addresses:"

for ip in "$${ip_list[@]}"
do
  echo $ip
done

echo "### Configuring dedicated EBS disks..."

cp /etc/fstab /etc/fstab.bak
for i in `seq 1 $num_instances`
do
  aws_device=$${device_list[i-1]}
  device_id=`echo $aws_device | sed 's/.*\/s/xv/'`
  device=/dev/$device_id
  echo "### Waiting on device $device_id..."
  until lsblk | grep -m 1 "$device_id"; do
    printf '.'
    sleep 1
  done

  echo "### Creating partition on $device..."
  (
  echo o
  echo n
  echo p
  echo 1
  echo
  echo
  echo w
  ) | fdisk $device
  mkfs.xfs -f $device

  echo "### Mounting partition..."
  mount_point=/data/node$i
  mkdir -p $mount_point
  mount -t xfs $device $mount_point
  echo "$device $mount_point xfs defaults 0 0" >> /etc/fstab
done

echo "### Configuring Instance Directories..."

directories=("commitlog" "data" "hints" "saved_caches")
data_location=/var/lib/cassandra
log_location=/var/log/cassandra
rm -rf $data_location/*
for i in `seq 1 $num_instances`
do
  # Data Directory
  location=$data_location/node$i
  ln -s /data/node$i $location
  for dir in "$${directories[@]}";
    do
      mkdir -p $location/$dir
  done
  # Log Directory
  mkdir -p $log_location/node$i
done
chown -R cassandra:cassandra /data
chown -R cassandra:cassandra $log_location

echo "### Creating common systemd service..."

cat <<EOF > /etc/systemd/system/cassandra3@.service
[Unit]
Description=Cassandra
Documentation=http://cassandra.apache.org
Wants=network-online.target
After=network-online.target

[Service]
Type=forking
User=cassandra
Group=cassandra

Environment="CASSANDRA_HOME=/usr/share/cassandra"
Environment="CASSANDRA_CONF=/etc/cassandra/%i"
Environment="PID_FILE=/var/run/cassandra-%i.pid"

ExecStart=/usr/sbin/cassandra -p $${PID_FILE}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=cassandra-%i
LimitNOFILE=100000
LimitMEMLOCK=infinity
LimitNPROC=32768
LimitAS=infinity

[Install]
WantedBy=multi-user.target
EOF

rsyslog_file=/etc/rsyslog.d/cassandra.conf
rm -f $rsyslog_file

echo "### Configuring Cassandra per Instance..."

for i in `seq 1 $num_instances`
do
  ip=$${ip_list[i-1]}
  conf_src=/etc/cassandra/conf
  conf_dir=/etc/cassandra/node$i
  data_dir=$data_location/node$i
  log_dir=$log_location/node$i
  conf_file=$conf_dir/cassandra.yaml
  env_file=$conf_dir/cassandra-env.sh
  jvm_file=$conf_dir/jvm.options

  log_file=$conf_dir/logback.xml
  rackdc_file=$conf_dir/cassandra-rackdc.properties

  # Copying files
  rsync -ar $conf_src/ $conf_dir/

  # Cassandra Configuration
  sed -r -i "/cluster_name/s/Test Cluster/${cluster_name}/" $conf_file
  sed -r -i "/seeds/s/127.0.0.1/${seed_name}/" $conf_file
  sed -r -i "/listen_address/s/localhost/$ip/" $conf_file
  sed -r -i "/rpc_address/s/localhost/$ip/" $conf_file
  sed -r -i "/endpoint_snitch/s/SimpleSnitch/GossipingPropertyFileSnitch/" $conf_file
  sed -r -i "s|hints_directory: .*|hints_directory: $data_dir/hints|" $conf_file
  sed -r -i "s|commitlog_directory: .*|commitlog_directory: $data_dir/commitlog|" $conf_file
  sed -r -i "s|saved_caches_directory: .*|saved_caches_directory: $data_dir/saved_caches|" $conf_file
  sed -r -i "s|/var/lib/cassandra/data|$data_dir/data|" $conf_file

  # Cassandra Tuning
  sed -r -i "s|^[# ]*?concurrent_compactors: .*|concurrent_compactors: 32|" $conf_file
  sed -r -i "s|^[# ]*?commitlog_total_space_in_mb: .*|commitlog_total_space_in_mb: 2048|" $conf_file

  # Cassandra Environment
  sed -r -i "/rmi.server.hostname/s/^\#//" $env_file
  sed -r -i "/rmi.server.hostname/s/.public name./$ip/" $env_file
  sed -r -i "/jmxremote.access/s/#//" $env_file
  sed -r -i "/LOCAL_JMX=/s/yes/no/" $env_file
  sed -r -i "/JMX_PORT/s/7199/7$${i}99/" $env_file
  sed -r -i "s|-Xloggc:.*.log|-Xloggc:$log_dir/gc.log|" $env_file
  sed -r -i "s/^[#]?MAX_HEAP_SIZE=\".*\"/MAX_HEAP_SIZE=\"${heap_size}m\"/" $env_file
  sed -r -i "s/^[#]?HEAP_NEWSIZE=\".*\"/HEAP_NEWSIZE=\"${heap_size}m\"/" $env_file

  # Disable CMSGC
  sed -r -i "/UseParNewGC/s/-XX/#-XX/" $jvm_file
  sed -r -i "/UseConcMarkSweepGC/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSParallelRemarkEnabled/s/-XX/#-XX/" $jvm_file
  sed -r -i "/SurvivorRatio/s/-XX/#-XX/" $jvm_file
  sed -r -i "/MaxTenuringThreshold/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSInitiatingOccupancyFraction/s/-XX/#-XX/" $jvm_file
  sed -r -i "/UseCMSInitiatingOccupancyOnly/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSWaitDuration/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSParallelInitialMarkEnabled/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSEdenChunksRecordAlways/s/-XX/#-XX/" $jvm_file
  sed -r -i "/CMSClassUnloadingEnabled/s/-XX/#-XX/" $jvm_file

  # Enable G1GC
  sed -r -i "/UseG1GC/s/#-XX/-XX/" $jvm_file
  sed -r -i "/G1RSetUpdatingPauseTimePercent/s/#-XX/-XX/" $jvm_file
  sed -r -i "/MaxGCPauseMillis/s/#-XX/-XX/" $jvm_file
  sed -r -i "/InitiatingHeapOccupancyPercent/s/#-XX/-XX/" $jvm_file
  sed -r -i "/ParallelGCThreads/s/#-XX/-XX/" $jvm_file

  # Cassandra logs
  sed -r -i "s|.cassandra.logdir.|{cassandra.logdir}/node$i|" $log_file

  # Configure DC/Rack options
  sed -r -i "s/dc1/${datacenter}/" $rackdc_file
  sed -r -i "s/rack1/${rack}/" $rackdc_file

  # Configure rsyslog
  echo "if \$programname == 'cassandra-node$i' then /var/log/cassandra/node$i/cassandra.log" >> $rsyslog_file
done

# Make sure that CASSANDRA_CONF is not overriden
infile=/usr/share/cassandra/cassandra.in.sh 
sed -r -i 's/^CASSANDRA_CONF/#CASSANDRA_CONF/' $infile 
echo 'if [ -z "$CASSANDRA_CONF" ]; then
  CASSANDRA_CONF=/etc/cassandra/conf
fi' | cat - $infile > /tmp/_temp && mv /tmp/_temp $infile

echo "### Configuring Common JMX..."

jmx_passwd=/etc/cassandra/jmxremote.password
jmx_access=/etc/cassandra/jmxremote.access

cat <<EOF > $jmx_passwd
monitorRole QED
controlRole R&D
cassandra cassandra
EOF
chmod 0400 $jmx_passwd
chown cassandra:cassandra $jmx_passwd

cat <<EOF > $jmx_access
monitorRole   readonly
cassandra     readwrite
controlRole   readwrite \
              create javax.management.monitor.*,javax.management.timer.* \
              unregister
EOF
chmod 0400 $jmx_access
chown cassandra:cassandra $jmx_access

echo "### Enabling and starting Cassandra instances..."

sleep ${startup_delay}
systemctl daemon-reload
systemctl restart rsyslog
for i in `seq 1 $num_instances`
do
  systemctl enable cassandra3@node$i
  systemctl start cassandra3@node$i
  sleep 45
done
