#!/bin/bash
set -eux

while read -r env; do export "$env"; done</etc/environment

#
ISSUPPORTED=$(echo -e "import hdinsight_common.ClusterManifestParser as ClusterManifestParser\nprint ClusterManifestParser.parse_local_manifest().settings.get('enable_security') == 'false'\ncluster_type=ClusterManifestParser.parse_local_manifest().settings.get('cluster_type')\ncluster_type == 'hadoop' or cluster_type == 'spark'" | python)
if [[ "$ISSUPPORTED" != "True" ]]; then 
  echo "Presto installation is only supported on hadoop cluster types. Other cluster types (Spark, Kafka, Secure Hadoop etc are not supported yet. Aborting." ; 
  exit 1
fi

# check if we have atleast 4 nodes
nodes=$(curl -L http://headnodehost:8088/ws/v1/cluster/nodes |  grep -o '"nodeHostName":"[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*"'  | wc -l)
if [[ $nodes -lt 4 ]]; then 
  echo "you need atleast 4 node hadoop cluster to run presto on HDI. Aborting."
  exit 1
fi 

default_fs=$(grep -n1 "fs.defaultFS" /etc/hadoop/conf/core-site.xml | grep -o "<value>.*/value>" | sed 's:<value>::g' | sed 's:</value>::g')
yarn_rm_address="--manager headnodehost:8050"
fs="--filesystem $default_fs"

VERSION=0.174

# clean up
test -e /var/lib/presto && rm -rf /var/lib/presto

mkdir -p /var/lib/presto
chmod -R 777 /var/lib/presto/


if [[ $(hostname -s) = hn0-* ]]; then 
  apt-get update
  which mvn &> /dev/null || apt-get -y -qq install maven
  cd /var/lib/presto
  wget https://github.com/papalukg/presto-hdinsight/archive/master.tar.gz -O presto-hdinsight.tar.gz
  tar xzf presto-hdinsight.tar.gz
  cd presto-hdinsight-master
  wget https://prestohdi.blob.core.windows.net/build/presto-yarn-package.zip -P build/
  slider package --install --name presto1 --package build/presto-yarn-package.zip --replacepkg $yarn_rm_address $fs
  ./createconfigs.sh $VERSION "${1:-}"
  slider resource --install --destdir /etc/hadoop/conf/ --resource wasb-site.xml --overwrite $yarn_rm_address
  slider exists presto1 --live $yarn_rm_address $fs && slider stop presto1 --force $yarn_rm_address $fs
  slider exists presto1 $yarn_rm_address $fs && slider destroy presto1 --force $yarn_rm_address $fs
  slider create presto1 --template appConfig-default.json --resources resources-default.json $yarn_rm_address $fs
fi

if [[ $(hostname -s) = hn* ]]; then 
  wget https://repo1.maven.org/maven2/com/facebook/presto/presto-cli/$VERSION/presto-cli-$VERSION-executable.jar -O /usr/local/bin/presto-cli
  chmod +x /usr/local/bin/presto-cli

  attempt=1

  until [[ -n "$(slider registry --name presto1 --getexp presto $yarn_rm_address 2>&1 | grep 'Exiting with status 0')" || $attempt -gt 60 ]]; do
    echo "waiting for presto to start.. attempt $attempt/60"
    let attempt+=1
    sleep 10
  done

  if [[ $attempt -gt 60 ]]; then
    echo "[Error] Presto failed to start in 10 mins after 60 attempts. Exiting."
    exit 1
  fi

  cat > /usr/local/bin/presto <<EOF
#!/bin/bash
presto-cli --server $(slider registry --name presto1 --getexp presto $yarn_rm_address | grep value | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*:[0-9]*") --catalog hive "\$@"
EOF
  
  chmod +x /usr/local/bin/presto
fi

# Test
if [[ $(hostname -s) = hn0-* ]]; then
  ./integration-tests.sh
fi
