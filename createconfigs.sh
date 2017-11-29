#!/bin/bash
set -eux

VERSION=$1
EXTRA_CONNECTORS="${2:+$2,}"
nodes=$(curl -L http://headnodehost:8088/ws/v1/cluster/nodes |  grep -o '"nodeHostName":"[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*"'  | wc -l)

metastore=$(grep -n1 "hive.metastore.uri" /etc/hive/conf/hive-site.xml | grep -o "<value>.*/value>" | sed 's:<value>::g' | sed 's:</value>::g')
memory=$(grep -n1 "yarn.nodemanager.resource.memory-mb" /etc/hadoop/conf/yarn-site.xml | grep -o "<value>.*/value>" | sed 's:<value>::g' | sed 's:</value>::g')
default_fs=$(grep -n1 "fs.defaultFS" /etc/hadoop/conf/core-site.xml | grep -o "<value>.*/value>" | sed 's:<value>::g' | sed 's:</value>::g')

#keep only what it really matters for presto
wasb_account_name_key=$(grep -C2 fs.azure.account.key /etc/hadoop/conf/core-site.xml)

cat > appConfig-default.json <<EOF
{
  "schema": "http://example.org/specification/v2.0.0",
  "metadata": {
  },
  "global": {
    "site.global.app_user": "root",
    "site.global.data_dir": "/var/lib/presto/data",
    "site.global.config_dir": "/var/lib/presto/etc",
    "site.global.app_name": "presto-server-$VERSION",
    "site.global.app_pkg_plugin": "\${AGENT_WORK_ROOT}/app/definition/package/plugins/",
    "site.global.singlenode": "false",
    "site.global.coordinator_host": "\${COORDINATOR_HOST}",
    "site.global.presto_query_max_memory": "$(($(($(($memory/1706))-1)) * $(($nodes-2))))GB",
    "site.global.presto_query_max_memory_per_node": "$(($(($memory/1706))-1))GB",
    "site.global.presto_server_port": "9090",
    "site.global.catalog": "{ $EXTRA_CONNECTORS 'hive': ['connector.name=hive-hadoop2','hive.metastore.uri=$metastore', 'hive.config.resources=.slider/resources/etc/hadoop/conf/wasb-site.xml'], 'tpch': ['connector.name=tpch']}",
    "site.global.jvm_args": "['-server', '-Xmx$(($(($memory/1024))-1))G', '-XX:+UseG1GC', '-XX:G1HeapRegionSize=32M', '-XX:+UseGCOverheadLimit', '-XX:+ExplicitGCInvokesConcurrent', '-XX:+HeapDumpOnOutOfMemoryError', '-XX:OnOutOfMemoryError=kill -9 %p']",
    "site.global.log_properties": "['com.facebook.presto=WARN']",
    "site.global.event_listener_properties": "['event-listener.name=event-logger']",
    "application.def": ".slider/package/presto1/presto-yarn-package.zip",
    "system_configs": "core-site, hdfs-site",
    "java_home": "/usr/lib/jvm/java"
  },
  "components": {
    "slider-appmaster": {
      "jvm.heapsize": "512M"
    }
  }
}
EOF

cat > resources-default.json <<EOF
{
  "schema": "http://example.org/specification/v2.0.0",
  "metadata": {
  },
  "global": {
    "yarn.vcores": "1"
  },
  "components": {
    "slider-appmaster": {
    },
    "COORDINATOR": {
      "yarn.role.priority": "1",
      "yarn.component.instances": "1",
      "yarn.component.placement.policy": "1",
      "yarn.memory": "$(($memory/2))"
    },
    "WORKER": {
      "yarn.role.priority": "2",
      "yarn.component.instances": "$(($nodes-1))",
      "yarn.component.placement.policy": "1",
      "yarn.memory": "$(($memory/2))"
    }
  }
}
EOF

cat > wasb-site.xml <<EOF
  <configuration>
     ${wasb_account_name_key}

     <property>
      <name>fs.azure.shellkeyprovider.script</name>
      <value>/usr/lib/hdinsight-common/scripts/decrypt.sh</value>
    </property>

    <property>
      <name>hadoop.security.key.provider.path</name>
      <value></value>
    </property>

  </configuration>
EOF
