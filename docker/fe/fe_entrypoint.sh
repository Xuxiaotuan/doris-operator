#!/bin/bash
DORIS_ROOT=${DORIS_ROOT:-"/opt/doris"}
DORIS_HOME=${DORIS_ROOT}/fe
ELECT_NUMBER=${ELECT_NUMBER:=3}
QUERY_PORT=${FE_QUERY_PORT:-9030}
DB_ADMIN_USER=${USER:-"root"}
FE_CONFFILE=$DORIS_HOME/conf/fe.conf
START_TYPE=
# FE leader
FE_LEADER=
POD_INDEX=
# probe interval: 2 seconds
PROBE_INTERVAL=2
# timeout for probe leader: 120 seconds
PROBE_LEADER_POD0_TIMEOUT=10 # at most 5 attempts, no less than the times needed for an election
PROBE_LEADER_PODX_TIMEOUT=120 # at most 60 attempts

# myself as IP or FQDN
MYSELF=


function log_stderr()
{
  echo "[`date`] $@" >& 2
}

parse_confval_from_fe_conf()
{
    # a naive script to grep given confkey from fe conf file
    # assume conf format: ^\s*<key>\s*=\s*<value>\s*$
    local confkey=$1
    local confvalue=`grep "\<$confkey\>" $FE_CONFFILE | grep -v '^\s*#' | sed 's|^\s*'$confkey'\s*=\s*\(.*\)\s*$|\1|g'`
    echo "$confvalue"
    lcoal
}

# start with exist meta.
function start_fe_with_meta()
{
    log_stderr "start with meta run start_fe.sh"
    $DORIS_HOME/fe/bin/start_fe.sh
}

parse_confval_from_fe_conf()
{
    # a naive script to grep given confkey from fe conf file
    # assume conf format: ^\s*<key>\s*=\s*<value>\s*$
    local confkey=$1
    local confvalue=`grep "\<$confkey\>" $FE_CONFFILE | grep -v '^\s*#' | sed 's|^\s*'$confkey'\s*=\s*\(.*\)\s*$|\1|g'`
    echo "$confvalue"
}

collect_env_info()
{
    # set POD_IP, POD_FQDN, POD_INDEX, EDIT_LOG_PORT, QUERY_PORT
    if [[ "x$POD_IP" == "x" ]] ; then
        POD_IP=`hostname -i | awk '{print $1}'`
    fi

    if [[ "x$POD_FQDN" == "x" ]] ; then
        POD_FQDN=`hostname -f`
    fi

    # example: fe-sr-deploy-1.fe-svc.kc-sr.svc.cluster.local
    POD_INDEX=`echo $POD_FQDN | awk -F'.' '{print $1}' | awk -F'-' '{print $NF}'`

    START_TYPE=`parse_confval_from_fe_conf "enable_fqdn_mode"`

    if [[ "x$START_TYPE" == "xtrue" ]]; then
        MYSELF=$POD_FQDN
    else
        MYSELF=$POD_IP
    fi

    # edit_log_port from conf file
    local edit_log_port=`parse_confval_from_fe_conf "edit_log_port"`
    if [[ "x$edit_log_port" != "x" ]] ; then
        EDIT_LOG_PORT=$edit_log_port
    fi

    # query_port from conf file
    local query_port=`parse_confval_from_fe_conf "query_port"`
    if [[ "x$query_port" != "x" ]] ; then
        QUERY_PORT=$query_port
    fi
}

# get all registered fe in cluster.
function show_frontends()
{
    local addr=$1
    echo ""
    timeout 15 mysql  --connect-timeout 2 -h $addr -P $QUERY_PORT -u root --skip-column-names --batch -e 'show frontends;'
}

function start_fe_no_meta()
{
    local addr=$1
    local opts=""
    local start=`date +%s`
    local has_member=false
    local member_list=
    if [[ "x$FE_LEADER" != "x" ]] ; then
        opts+=" --helper $FE_LEADER:$EDIT_LOG_PORT"
        local start=`date +%s`
        while true
        do
            if [[ ELECT_NUMBER -gt $POD_INDEX ]]; then
                log_stderr "Add myself($MYSELF:$EDIT_LOG_PORT) to leader as follower ..."
                mysql --connect-timeout 2 -h $FE_LEADER -P $QUERY_PORT -u root --skip-column-names --batch -e "ALTER SYSTEM ADD FOLLOWER \"$MYSELF:$EDIT_LOG_PORT\";"
            else
                log_stderr "Add myself($MYSELF:$EDIT_LOG_PORT) to leader as observer ..."
                mysql --connect-timeout 2 -h $FE_LEADER -P $QUERY_PORT -u root --skip-column-names --batch -e "ALTER SYSTEM ADD OBSERVER \"$MYSELF:$EDIT_LOG_PORT\";"
            fi
               # check if added successful
               if show_frontends $addr | grep -q -w "$MYSELF" &>/dev/null ; then
                   break;
               fi

               local now=`date +%s`
               let "expire=start+30" # 30s timeout
               if [[ $expire -le $now ]] ; then
                   log_stderr "Timed out, abort!"
                   exit 1
               fi

               log_stderr "Sleep a while and retry adding ..."
               sleep $PROBE_INTERVAL
           done
    fi
    log_stderr "first start with no meta run start_fe.sh with additional options: '$opts'"
    $DORIS_HOME/bin/start_fe.sh $opts
}


probe_leader_for_pod0()
{
    # possible to have no result at all, because myself is the first FE instance in the cluster
    local svc=$1
    local start=`date +%s`
    local has_member=false
    local memlist=
    while true
    do
        memlist=`show_frontends $svc`
        #local leader=`echo "$memlist" | grep '\<LEADER\>' | awk '{print $2}'`
	    local leader=`echo "$memlist" | grep '\<FOLLOWER\>' | awk -F '\t' '{if ($8=="true") print $2}'`
        if [[ "x$leader" != "x" ]] ; then
            # has leader, done
            log_stderr "Find leader: $leader!"
            FE_LEADER=$leader
            return 0
        fi

        if [[ "x$memlist" != "x" ]] ; then
            # has memberlist ever before
            has_member=true
        fi

        # no leader yet, check if needs timeout and quit
        log_stderr "No leader yet, has_member: $has_member ..."
        local timeout=$PROBE_LEADER_POD0_TIMEOUT
        if $has_member ; then
            # set timeout to the same as PODX since there are other members
            timeout=$PROBE_LEADER_PODX_TIMEOUT
        fi

        local now=`date +%s`
        let "expire=start+timeout"
        if [[ $expire -le $now ]] ; then
            if $has_member ; then
                log_stderr "Timed out ${timeout}s, abort!"
                exit 1
            else
                log_stderr "Timed out, no members detected ever, assume myself is the first node .."
                # empty FE_LEADER
                FE_LEADER=""
                return 0
            fi
        fi
        sleep $PROBE_INTERVAL
    done
}

probe_leader_for_podX()
{
    # wait until find a leader or timeout
    local svc=$1
    local start=`date +%s`
    while true
    do
        #local leader=`show_frontends $svc | grep '\<LEADER\>' | awk '{print $2}'`
        memlist=`show_frontends $svc`
	local leader=`echo "$memlist" | grep '\<FOLLOWER\>' | awk -F '\t' '{if ($8=="true") print $2}'`
        if [[ "x$leader" != "x" ]] ; then
            # has leader, done
            log_stderr "Find leader: $leader!"
            FE_LEADER=$leader
            return 0
        fi
        # no leader yet, check if needs timeout and quit
        log_stderr "No leader yet ..."

        local now=`date +%s`
        let "expire=start+PROBE_LEADER_PODX_TIMEOUT"
        if [[ $expire -le $now ]] ; then
            log_stderr "Timed out, abort!"
            exit 1
        fi

        sleep $PROBE_INTERVAL
    done
}

probe_leader()
{
    local svc=$1

    # find leader under current service and set to FE_LEADER
    if [[ "$POD_INDEX" -eq 0 ]] ; then
        probe_leader_for_pod0 $svc
    else
        probe_leader_for_podX $svc
    fi
}

update_conf_from_configmap()
{
    if [[ "x$CONFIGMAP_MOUNT_PATH" == "x" ]] ; then
        log_stderr 'Empty $CONFIGMAP_MOUNT_PATH env var, skip it!'
        return 0
    fi
    if ! test -d $CONFIGMAP_MOUNT_PATH ; then
        log_stderr "$CONFIGMAP_MOUNT_PATH not exist or not a directory, ignore ..."
        return 0
    fi
    local tgtconfdir=$DORIS_HOME/conf
    for conffile in `ls $CONFIGMAP_MOUNT_PATH`
    do
        log_stderr "Process conf file $conffile ..."
        local tgt=$tgtconfdir/$conffile
        if test -e $tgt ; then
            # make a backup
            mv -f $tgt ${tgt}.bak
        fi
        ln -sfT $CONFIGMAP_MOUNT_PATH/$conffile $tgt
    done
}

start_fe_with_meta()
{
    local opts=""
    log_stderr "start with meta run start_fe.sh with additional options: '$opts'"
    $DORIS_HOME/bin/start_fe.sh $opts
}

fe_addrs=$1
if [[ "x$fe_addrs" == "x" ]]; then
    echo "need fe address as parameter!"
    exit
fi

update_conf_from_configmap
if [[ -f "/opt/doris/fe/doris-meta/image/ROLE" ]]; then
    log_stderr "start fe with exist meta."
    start_fe_with_meta
else
    log_stderr "first start fe with meta not exist."
    collect_env_info
    probe_leader $fe_addrs
    start_fe_no_meta $fe_addrs
fi
