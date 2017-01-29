#!/bin/bash -e

ROOT_DIR=$(realpath "$(dirname $(realpath $0))/.." )

export $(cat $ROOT_DIR/etc/env.sh)

if [ "$DEBUG" = "1" ]; then
  set -x
fi

# PREFIX="##"
# H1_PREFIX=$PREFIX
# H2_PREFIX=$PREFIX
# INFO_PREFIX=$PREFIX
# ERROR_PREFIX=$PREFIX

H1_PREFIX="##"
H2_PREFIX="--"
INFO_PREFIX="##"
ERROR_PREFIX="##"
HR_CHAR="-"
THEME_COLOR="\033[38;1;34m"
H1_COLOR="\033[1;6m"
H2_COLOR="\033[1;6m"
TEXT_COLOR="\033[1;6m"
SUCCESS_COLOR="\033[1;38;5;10m"
FAILED_COLOR="\033[1;38;5;9m"

function print_h1() {
  print_hr ' '
  printf "\n${THEME_COLOR}${H1_PREFIX}\033[0m ${H1_COLOR}$1\033[0m\n\n"
  print_hr
  echo
}

function print_h2() {
  printf "\n${THEME_COLOR}${H2_PREFIX}\033[0m ${H2_COLOR}$1\033[0m\n\n"
}

function print_hr() {
  CHAR=${1:-"$HR_CHAR"}
  declare -i REAL_COLUMNS="${COLUMNS:-$(tput cols)}"
  printf "${THEME_COLOR}%*s\033[0m\n" "${REAL_COLUMNS:-80}" '' | tr ' ' "${CHAR}"
}

function print_info() {
  echo
  print_hr
  printf "\n${THEME_COLOR}${INFO_PREFIX}\033[0m ${TEXT_COLOR}$1 command \033[0m-- ${SUCCESS_COLOR}completed!\033[0m\n\n"
}

function print_error() {
  echo
  print_hr
  printf "\n${THEME_COLOR}${ERROR_PREFIX}\033[0m ${TEXT_COLOR}$1 command \033[0m-- ${FAILED_COLOR}failed!\033[0m\n\n"
}

function print_node_info() {
  cd_docker_dir
  docker-compose exec $1 bash -c "gosu postgres pcp_node_info -n $2 -w" \
  | tr -d '\r' \
  | eval "awk '{ printf \"${TEXT_COLOR}%-8s\\033[0m -- backend: ${TEXT_COLOR}%-8s\\033[0m port: ${TEXT_COLOR}%-6s\\033[0m weight: ${TEXT_COLOR}%-9s\\033[0m status: ${TEXT_COLOR}%s\\033[0m \\n\", \"$1\", \$1, \$2, \$4, \$5 }'"
  cd_root_dir
}

function cd_root_dir() {
  cd $ROOT_DIR > /dev/null
}

function cd_docker_dir() {
  cd $ROOT_DIR/docker > /dev/null
}

function is_running() {
  (docker-compose ps | grep $1 | grep Up >/dev/null && echo 1) || echo 0
}

function is_dirty() {
  declare -i EXIT_CODE=$(docker-compose ps | grep $1 | grep Exit | awk '{ print $4 }')
  if [[ $EXIT_CODE -eq 0 || $EXIT_CODE -eq 2 ]]; then
    echo 0
  else
    echo 1
  fi
}

function is_in_recovery() {
  declare -i IS_RUNNING=$(is_running $1)
  if [ $IS_RUNNING -eq 1 ]; then
    docker-compose exec $1 bash -c "gosu postgres psql -Atnxc 'select pg_is_in_recovery();' postgres | awk -F '|' '{ print \$2 }'" | tr -d '\r'
  else
    declare -a DB_STATE="$(docker-compose run --no-deps --rm -T --entrypoint bash $1 -c "gosu postgres pg_controldata | grep 'Database cluster state:'  | awk -F 'state:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2; }'" | tr -d '\r')"
    if [ "$DB_STATE" = "in archive recovery" ]; then
      echo 't'
    else
      echo 'f'
    fi
  fi
}

function detect_recovery_target() {
  [ "$PWD" != "$ROOT_DIR/docker" ] && cd_docker_dir
  declare -i MASTER_IS_RUNNING=$(is_running master)
  declare -i STANDBY_IS_RUNNING=$(is_running standby)

  MASTER_DOCKER_OPTS="run --no-deps --rm -T --entrypoint bash master -c"
  if [ $MASTER_IS_RUNNING -eq 1 ]; then
    MASTER_DOCKER_OPTS="exec master bash -c"
  fi

  STANDBY_DOCKER_OPTS="run --no-deps --rm -T --entrypoint bash standby -c"
  if [ $STANDBY_IS_RUNNING -eq 1 ]; then
    STANDBY_DOCKER_OPTS="exec standby bash -c"
  fi

  declare -i MASTER_TIMELINE="$(docker-compose ${MASTER_DOCKER_OPTS} "gosu postgres pg_controldata | grep ' TimeLineID' | awk -F 'TimeLineID:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2 }'" | tr -d '\r')"
  declare -i STANDBY_TIMELINE="$(docker-compose ${STANDBY_DOCKER_OPTS} "gosu postgres pg_controldata | grep ' TimeLineID' | awk -F 'TimeLineID:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2 }'" | tr -d '\r')"

  MASTER_STATE="$(docker-compose $MASTER_DOCKER_OPTS "gosu postgres pg_controldata | grep 'Database cluster state' | awk -F ':' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2; }'" | tr -d '\r')"
  STANDBY_STATE="$(docker-compose $STANDBY_DOCKER_OPTS "gosu postgres pg_controldata | grep 'Database cluster state' | awk -F ':' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2; }'" | tr -d '\r')"

  if [[ "${MASTER_STATE}" == "in production" && $STANDBY_IS_RUNNING -eq 0 && $MASTER_TIMELINE -ge $STANDBY_TIMELINE ]]; then
    echo 1
  elif [[ "${STANDBY_STATE}" == "in production" && $MASTER_IS_RUNNING -eq 0 && $STANDBY_TIMELINE -ge $MASTER_TIMELINE ]]; then
    echo 0
  else
    echo -1
  fi

  [ "$OLDPWD" != "$ROOT_DIR/docker" ] && cd - >/dev/null
}

function wait_for_db() {
  TIMEOUT=5
  MAX_TRIES=50
  while [[ "$MAX_TRIES" != "0" ]]; do
    if [ "$1" != "" ]; then
      EXISTS=$(docker-compose exec -T $1 gosu postgres psql -tnAc "SELECT 1" postgres || true)
      if [ "${EXISTS}" != "1" ]; then
        sleep $TIMEOUT
      else
        break
      fi
    else
      MASTER_EXISTS=$(docker-compose exec -T master gosu postgres psql -tnAc "SELECT 1" postgres || true)
      STANDBY_EXISTS=$(docker-compose exec -T standby gosu postgres psql -tnAc "SELECT 1" postgres || true)
      if [[ "$MASTER_EXISTS" != "1" || "$STANDBY_EXISTS" != "1" ]]; then
        sleep $TIMEOUT
      else
        break
      fi
    fi
    MAX_TRIES=`expr "$MAX_TRIES" - 1`
  done
}

function enable_ssh_auth() {
  USER_NAME=$1
  USER_HOMEDIR=$(docker-compose exec master bash -c "grep $USER_NAME /etc/passwd" | awk -F ':' '{ print $6 }')
  [[ "$USER_NAME" == "root" || "$USER_NAME" == "postgres" ]] || exit 1

  MASTER_PUB_KEY="$(docker-compose exec --user $USER_NAME master cat $USER_HOMEDIR/.ssh/id_rsa.pub)"
  STANDBY_PUB_KEY="$(docker-compose exec --user $USER_NAME standby cat $USER_HOMEDIR/.ssh/id_rsa.pub)"

  docker-compose exec -T --user $USER_NAME master bash -c "echo \"$STANDBY_PUB_KEY\" >> $USER_HOMEDIR/.ssh/authorized_keys"
  docker-compose exec -T --user $USER_NAME standby bash -c "echo \"$MASTER_PUB_KEY\" >> $USER_HOMEDIR/.ssh/authorized_keys"
  docker-compose exec -T --user $USER_NAME master bash -c "ssh-keyscan -H standby,$STANDBY_IP >> $USER_HOMEDIR/.ssh/known_hosts"
  docker-compose exec -T --user $USER_NAME standby bash -c "ssh-keyscan -H master,$MASTER_IP >> $USER_HOMEDIR/.ssh/known_hosts"
}

function init() {
  print_h1 "Initializing PostgreSQL cluster."
  cd_docker_dir

  printf "\033[1A"
  print_h2 "Shuting down existing cluster."
  docker-compose down

  print_h2 "Building image."
  docker-compose build

  print_h2 "Pushing image."
  docker-compose push

  print_h2 "Pulling image on all nodes."
  docker-compose pull

  print_h2 "Moving existing data folders."

  TS=$(date +%Y%m%d-%H%M%S)
  docker-machine ssh $MASTER_NODE mv -vf /data/docker/$COMPOSE_PROJECT_NAME /data/docker/$COMPOSE_PROJECT_NAME-$TS
  docker-machine ssh $STANDBY_NODE mv -vf /data/docker/$COMPOSE_PROJECT_NAME /data/docker/$COMPOSE_PROJECT_NAME-$TS

  print_h2 "Enabling SSH authentication."
  docker-compose up -d
  sleep 10
  enable_ssh_auth root
  enable_ssh_auth postgres
  docker-compose down

  print_h2 "Starting PostgreSQL cluster."
  docker-compose up -d
  wait_for_db
  docker-compose exec -T master gosu postgres psql -c "create table if not exists rewindtest (t text);" postgres
  cd_root_dir
}

function start() {
  print_h1 "Starting PostgreSQL cluster..."
  cd_docker_dir
  docker-compose up -d
  cd_root_dir
}

function stop() {
  print_h1 "Stopping PostgreSQL cluster..."
  cd_docker_dir
  docker-compose down
  cd_root_dir
}

function status() {
  print_h1 "Checking PostgreSQL cluster status..."
  cd_docker_dir
  declare -i MASTER_IS_RUNNING=$(is_running master)
  declare -i MASTER_IS_DIRTY=$(is_dirty master)
  declare -a MASTER_IS_IN_RECOVERY=$(is_in_recovery master)
  declare -i STANDBY_IS_RUNNING=$(is_running standby)
  declare -i STANDBY_IS_DIRTY=$(is_dirty standby)
  declare -a STANDBY_IS_IN_RECOVERY=$(is_in_recovery standby)

  if [ $MASTER_IS_RUNNING -eq 1 ]; then
    MASTER_IS_RUNNING_STR="${SUCCESS_COLOR}true\033[0m"
    MASTER_DOCKER_OPTS="exec master bash -c"
    if [ "$MASTER_IS_IN_RECOVERY" = "f" ]; then
      MASTER_XLOG_LOCATION=$(docker-compose ${MASTER_DOCKER_OPTS} "gosu postgres psql -Atnxc 'select pg_current_xlog_location()' postgres | awk -F '|' '{ print \$2 }'" | tr -d '\r')
    else
      MASTER_XLOG_LOCATION=$(docker-compose ${MASTER_DOCKER_OPTS} "gosu postgres psql -Atnxc 'select pg_last_xlog_replay_location()' postgres | awk -F '|' '{ print \$2 }'" | tr -d '\r')
    fi
  else
    MASTER_DOCKER_OPTS="run --no-deps --rm -T --entrypoint bash master -c"
    MASTER_XLOG_LOCATION=$(docker-compose ${MASTER_DOCKER_OPTS} "gosu postgres pg_controldata | grep 'Latest checkpoint location:'  | awk -F 'location:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2; }'" | tr -d '\r')
  fi

  if [ $STANDBY_IS_RUNNING -eq 1 ]; then
    STANDBY_DOCKER_OPTS="exec standby bash -c"
    if [ "$STANDBY_IS_IN_RECOVERY" = "f" ]; then
      STANDBY_XLOG_LOCATION=$(docker-compose ${STANDBY_DOCKER_OPTS} "gosu postgres psql -Atnxc 'select pg_current_xlog_location()' postgres | awk -F '|' '{ print \$2 }'" | tr -d '\r')
    else
      STANDBY_XLOG_LOCATION=$(docker-compose ${STANDBY_DOCKER_OPTS} "gosu postgres psql -Atnxc 'select pg_last_xlog_replay_location()' postgres | awk -F '|' '{ print \$2 }'" | tr -d '\r')
    fi
  else
    STANDBY_DOCKER_OPTS="run --no-deps --rm -T --entrypoint bash standby -c"
    STANDBY_XLOG_LOCATION=$(docker-compose ${STANDBY_DOCKER_OPTS} "gosu postgres pg_controldata | grep 'Latest checkpoint location:'  | awk -F 'location:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2; }'" | tr -d '\r')
  fi

  declare -i MASTER_TIMELINE="$(docker-compose ${MASTER_DOCKER_OPTS} "gosu postgres pg_controldata | grep ' TimeLineID' | awk -F 'TimeLineID:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2 }'" | tr -d '\r')"
  declare -i STANDBY_TIMELINE="$(docker-compose ${STANDBY_DOCKER_OPTS} "gosu postgres pg_controldata | grep ' TimeLineID' | awk -F 'TimeLineID:' '{ gsub(/^[ \\t]+/, \"\", \$2); print \$2 }'" | tr -d '\r')"


  printf "\033[1A"
  print_h2 "Cluster nodes"

  printf "%s -- running: %s dirty: %s recovery: %s location: %s timeline: %s\n" \
    "$(printf "${TEXT_COLOR}%-8s\033[0m" "master")" \
    "$(([ $MASTER_IS_RUNNING -eq 1 ] && printf "${SUCCESS_COLOR}%-6s\033[0m" "true") || printf "${FAILED_COLOR}%-6s\033[0m" "false")" \
    "$( ([ $MASTER_IS_DIRTY -eq 1 ] && printf "${FAILED_COLOR}%-6s\033[0m" "true") || printf "${SUCCESS_COLOR}%-6s\033[0m" "false")" \
    "$(([ "$MASTER_IS_IN_RECOVERY" = "t" ] && printf "${TEXT_COLOR}%-6s\033[0m" "true") || printf "${TEXT_COLOR}%-6s\033[0m" "false")" \
    "$(printf "${TEXT_COLOR}${MASTER_XLOG_LOCATION} \033[0m")" \
    "$(printf "${TEXT_COLOR}${MASTER_TIMELINE}\033[0m")"

  printf "%s -- running: %s dirty: %s recovery: %s location: %s timeline: %s\n" \
    "$(printf "${TEXT_COLOR}%-8s\033[0m" "standby")" \
    "$(([ $STANDBY_IS_RUNNING -eq 1 ] && printf "${SUCCESS_COLOR}%-6s\033[0m" "true") || printf "${FAILED_COLOR}%-6s\033[0m" "false")" \
    "$( ([ $STANDBY_IS_DIRTY -eq 1 ] && printf "${FAILED_COLOR}%-6s\033[0m" "true") || printf "${SUCCESS_COLOR}%-6s\033[0m" "false")" \
    "$(([ "$STANDBY_IS_IN_RECOVERY" = "t" ] && printf "${TEXT_COLOR}%-6s\033[0m" "true") || printf "${TEXT_COLOR}%-6s\033[0m" "false")" \
    "$(printf "${TEXT_COLOR}${STANDBY_XLOG_LOCATION} \033[0m")" \
    "$(printf "${TEXT_COLOR}${STANDBY_TIMELINE}\033[0m")"


  print_h2 "Load balancers"
  if [ $MASTER_IS_RUNNING -eq 1 ]; then
    print_node_info master 0
    print_node_info master 1
  fi

  if [ $STANDBY_IS_RUNNING -eq 1 ]; then
    print_node_info standby 0
    print_node_info standby 1
  fi



  print_h2 "Overall status"
  if [[ $MASTER_IS_RUNNING -eq 0 && $STANDBY_IS_RUNNING -eq 1 ]]; then
    DEGRADED=1
    HEALTH=1
  elif [[ $MASTER_IS_RUNNING -eq 1 && $STANDBY_IS_RUNNING -eq 0 ]]; then
    DEGRADED=1
    HEALTH=1
  fi

  if [[ $MASTER_IS_RUNNING -eq 0 && $STANDBY_IS_RUNNING -eq 0 ]]; then
    HEALTH=0
    if [[ $MASTER_TIMELINE -ne $STANDBY_TIMELINE ]]; then
      DEGRADED=1
    fi
  elif [[ $MASTER_IS_RUNNING -eq 1 && $STANDBY_IS_RUNNING -eq 1 ]]; then
    HEALTH=1
    if [[ $MASTER_TIMELINE -ne $STANDBY_TIMELINE ]]; then
      DEGRADED=1
    else
      DEGRADED=0
    fi
  fi

  if [[ $MASTER_TIMELINE -ge $STANDBY_TIMELINE && "$MASTER_IS_IN_RECOVERY" = "f" ]]; then
    PRIMARY=master
  elif [[ $STANDBY_TIMELINE -ge $MASTER_TIMELINE && "$STANDBY_IS_IN_RECOVERY" = "f" ]]; then
    PRIMARY=standby
  fi

  printf "primary: %s operational: %s degraded: %s\n" \
  "$(printf "${TEXT_COLOR}%-s \033[0m" $PRIMARY)" \
  "$( ([ $HEALTH -eq 1 ] && printf "${SUCCESS_COLOR}%-s \033[0m" "true") || printf "${FAILED_COLOR}%-s \033[0m" "false")" \
  "$( ([ $DEGRADED -eq 0 ] && printf "${SUCCESS_COLOR}%-s\033[0m" "false") || printf "${FAILED_COLOR}%-s\033[0m" "true")"

  cd_root_dir
}

function failover() {
  print_h1 "Starting $FUNCNAME..."
  cd_docker_dir
  docker-compose exec -T master gosu postgres psql -c "insert into rewindtest values ('in master');" postgres
  docker-compose exec -T standby gosu postgres psql -tnAc "select * from rewindtest;" postgres
  docker-compose kill master
  docker-compose exec -T standby gosu postgres pg_ctl promote -w
  sleep 5
  docker-compose exec -T standby gosu postgres psql -c "insert into rewindtest values ('in standby')" postgres
  docker-compose exec -T standby gosu postgres psql -tnAc "select * from rewindtest;" postgres
  docker-compose exec -T standby gosu postgres psql -tnxc "select pg_is_in_recovery();" postgres
  cd_root_dir
}

function recovery() {
  print_h1 "Starting $FUNCNAME..."
  cd_docker_dir

  printf "\033[1A"
  print_h2 "Discovering recovery target."
  declare -i RECOVERY_NODE=$(detect_recovery_target)

  if [ $RECOVERY_NODE -eq 0 ]; then
    RECOVERY_SOURCE=standby
    RECOVERY_TARGET=master
  elif [ $RECOVERY_NODE -eq 1 ]; then
    RECOVERY_SOURCE=master
    RECOVERY_TARGET=standby
  else
    echo "Nothing to recover. Exiting..."
    exit 0
  fi

  print_h2 "Preparing for replication ($RECOVERY_SOURCE -> $RECOVERY_TARGET)."
# exit 0
  docker-compose stop $RECOVERY_TARGET

  declare -i IS_DIRTY=$(is_dirty $RECOVERY_TARGET)
  if [ $IS_DIRTY -eq 1 ]; then
    docker-compose run --no-deps --rm --entrypoint bash $RECOVERY_TARGET -c "gosu postgres pg_ctl -D $PGDATA -w start && gosu postgres pg_ctl -D $PGDATA -w stop"
  fi

  print_h2 "Syncing pg_xlog."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "rsync -avz $RECOVERY_SOURCE:$PGDATA/pg_xlog/ $PGDATA/pg_xlog/"

  print_h2 "Syncing archive logs."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "rsync -avz $RECOVERY_SOURCE:$CLUSTER_ARCHIVE/ $CLUSTER_ARCHIVE/"

  print_h2 "Syncing data directory."
  docker-compose run --no-deps --rm --entrypoint bash $RECOVERY_TARGET -c "gosu postgres pg_rewind --target-pgdata=$PGDATA --source-server='host=$RECOVERY_SOURCE port=$PGPORT dbname=postgres user=$POSTGRES_USER  password=$POSTGRES_PASSWORD'"


  print_h2 "Configuring recovery target ($RECOVERY_TARGET)."
  if [ $RECOVERY_SOURCE == "master" ]; then
    RECOVERY_FILE=$(docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "(test -f $PGDATA/recovery.done && cat $PGDATA/recovery.done) || cat $PGDATA/recovery.conf")
    NEW_RECOVERY_FILE=$(echo "$RECOVERY_FILE" | sed -e "s/host=$RECOVERY_TARGET/host=$RECOVERY_SOURCE/")
    docker-compose run --no-deps --rm -T --entrypoint bash -e "NEW_RECOVERY_FILE=$NEW_RECOVERY_FILE" $RECOVERY_TARGET -c "echo \"$NEW_RECOVERY_FILE\" > $PGDATA/recovery.conf"
    docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chown postgres:postgres $PGDATA/recovery.conf"
  else
    RECOVERY_FILE=$(docker-compose exec $RECOVERY_SOURCE bash -c "(test -f $PGDATA/recovery.done && cat $PGDATA/recovery.done) || cat $PGDATA/recovery.conf")
    NEW_RECOVERY_FILE=$(echo "$RECOVERY_FILE" | sed -e "s/host=$RECOVERY_TARGET/host=$RECOVERY_SOURCE/")
    docker-compose run --no-deps --rm -T --entrypoint bash -e "NEW_RECOVERY_FILE=$NEW_RECOVERY_FILE" $RECOVERY_TARGET -c "echo \"$NEW_RECOVERY_FILE\" > $PGDATA/recovery.conf"
    docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chown postgres:postgres $PGDATA/recovery.conf"
  fi

  print_h2 "Starting recovery target ($RECOVERY_TARGET)."
  docker-compose start $RECOVERY_TARGET
  wait_for_db $RECOVERY_TARGET

  print_h2 "Attaching node."
  docker-compose exec $RECOVERY_SOURCE gosu postgres pcp_attach_node -w -n $RECOVERY_NODE
  cd_root_dir
}

function full_recovery() {
  print_h1 "Starting $(echo $FUNCNAME | awk '{ gsub(/_/, " ", $0); print; }')..."
  cd_docker_dir

  declare -i RECOVERY_NODE=$(detect_recovery_target)
  if [ $RECOVERY_NODE -eq 0 ]; then
    RECOVERY_SOURCE=standby
    RECOVERY_TARGET=master
  elif [ $RECOVERY_NODE -eq 1 ]; then
    RECOVERY_SOURCE=master
    RECOVERY_TARGET=standby
  else
    echo "Nothing to recover. Exiting..."
    exit 0
  fi

  printf "\033[1A"
  print_h2 "Preparing for replication ($RECOVERY_SOURCE -> $RECOVERY_TARGET)."

  [ "$(is_running $RECOVERY_TARGET)" = "1" ] && docker-compose stop $RECOVERY_TARGET
  [ "$(is_running $RECOVERY_SOURCE)" = "0" ] && docker-compose start $RECOVERY_SOURCE

  print_h2 "Removing old data directory ($RECOVERY_TARGET)."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "rm -rf $PGDATA/*"

  print_h2 "Syncing data directory."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "gosu postgres pg_basebackup -D $PGDATA -w -X stream -d 'host=$RECOVERY_SOURCE port=$PGPORT user=$REPLICATION_USER password=$REPLICATION_PASSWORD'"
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chmod 0700 $PGDATA"
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chown -R postgres:postgres $PGDATA"

  print_h2 "Syncing pg_xlog."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "rsync -avz $RECOVERY_SOURCE:$PGDATA/pg_xlog/ $PGDATA/pg_xlog/"

  print_h2 "Syncing archive logs."
  docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "rsync -avz $RECOVERY_SOURCE:$CLUSTER_ARCHIVE/ $CLUSTER_ARCHIVE/"

  print_h2 "Configuring recovery target ($RECOVERY_TARGET)."
  if [ $RECOVERY_SOURCE == "master" ]; then
    RECOVERY_FILE=$(docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "(test -f $PGDATA/recovery.done && cat $PGDATA/recovery.done) || cat $PGDATA/recovery.conf")
    NEW_RECOVERY_FILE=$(echo "$RECOVERY_FILE" | sed -e "s/host=$RECOVERY_TARGET/host=$RECOVERY_SOURCE/")
    docker-compose run --no-deps --rm -T --entrypoint bash -e "NEW_RECOVERY_FILE=$NEW_RECOVERY_FILE" $RECOVERY_TARGET -c "echo \"$NEW_RECOVERY_FILE\" > $PGDATA/recovery.conf"
    docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chown postgres:postgres $PGDATA/recovery.conf"
  else
    RECOVERY_FILE=$(docker-compose exec $RECOVERY_SOURCE bash -c "(test -f $PGDATA/recovery.done && cat $PGDATA/recovery.done) || cat $PGDATA/recovery.conf")
    NEW_RECOVERY_FILE=$(echo "$RECOVERY_FILE" | sed -e "s/host=$RECOVERY_TARGET/host=$RECOVERY_SOURCE/")
    docker-compose run --no-deps --rm -T --entrypoint bash -e "NEW_RECOVERY_FILE=$NEW_RECOVERY_FILE" $RECOVERY_TARGET -c "echo \"$NEW_RECOVERY_FILE\" > $PGDATA/recovery.conf"
    docker-compose run --no-deps --rm -T --entrypoint bash $RECOVERY_TARGET -c "chown postgres:postgres $PGDATA/recovery.conf"
  fi

  print_h2 "Starting recovery target ($RECOVERY_TARGET)."
  docker-compose start $RECOVERY_TARGET
  wait_for_db $RECOVERY_TARGET

  print_h2 "Attaching node."
  docker-compose exec -T $RECOVERY_SOURCE gosu postgres pcp_attach_node -w -n $RECOVERY_NODE
  cd_root_dir
}

function failback() {
  print_h1 "Starting $FUNCNAME..."
  cd_docker_dir


  # TODO add pre-checks


  printf "\033[1A"
  print_h2 "Preparing for replication (standby -> master)."
  docker-compose stop standby
  docker-compose exec -T master gosu postgres pg_ctl promote -w
  sleep 5

  print_h2 "Syncing archive logs."
  docker-compose run --no-deps --rm -T standby rsync -avz master:$CLUSTER_ARCHIVE/ $CLUSTER_ARCHIVE/

  print_h2 "Syncing data directory."
  docker-compose run --no-deps --rm -T standby gosu postgres pg_rewind --target-pgdata=$PGDATA --source-server="host=master port=$PGPORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASSWORD"

  print_h2 "Configuring recovery target (standby)."
  RECOVERY_FILE=$(docker-compose exec master bash -c "(test -f $PGDATA/recovery.done && cat $PGDATA/recovery.done) || cat $PGDATA/recovery.conf")
  NEW_RECOVERY_FILE=$(echo "$RECOVERY_FILE" | sed -e "s/host=standby/host=master/")

  docker-compose run --no-deps --rm -T standby bash -c "echo \"$NEW_RECOVERY_FILE\" > $PGDATA/recovery.conf"
  docker-compose run --no-deps --rm -T standby chown postgres:postgres $PGDATA/recovery.conf

  print_h2 "Starting recovery target (standby)."
  docker-compose start standby
  wait_for_db "standby"

  print_h2 "Attaching node."
  docker-compose exec -T master gosu postgres pcp_attach_node -w -n 1
  cd_root_dir
}

function full_failback() {
  print_h1 "Starting $(echo $FUNCNAME | awk '{ gsub(/_/, " ", $0); print; }')..."
  cd_docker_dir
  docker-compose stop standby
  docker-compose exec -T master gosu postgres pg_ctl promote -w
  sleep 5
  docker-compose run --no-deps --rm -T standby bash -c "rm -rf $PGDATA/*"
  docker-compose start standby
  wait_for_db "standby"
  docker-compose exec -T master gosu postgres pcp_attach_node -w -n 1
  docker-compose exec -T master gosu postgres psql -c "insert into rewindtest values ('in master / failback')" postgres
  docker-compose exec standby gosu postgres psql -tnAc "select * from rewindtest;" postgres
  docker-compose exec master gosu postgres psql -tnxc "select pg_is_in_recovery();" postgres
  docker-compose exec standby gosu postgres psql -tnxc "select pg_is_in_recovery();" postgres
  cd_root_dir
}

FUNC=$1; shift
(eval "$FUNC $@") || (print_error $1 && exit 1)
print_info $1