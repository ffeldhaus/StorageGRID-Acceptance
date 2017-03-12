#!/bin/bash
### Copyright 2017 NetApp Deutschland GmbH
### Author: Florian Feldhaus

OPTS=`getopt -n 'parse-options' -o vhnsudbeco: --long verbose,help,dry-run,size:,upload-count:,upload-hours:,download-count:,download-hours:,bridges:,s3-endpoint:,clients:,output-directory: -- "$@"`
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

VERBOSE=false
HELP=false
DRY_RUN=false
OUTPUT_DIRECTORY=/tmp

function usage {
    echo "Usage: $0 [-vhn] -s|--size size -u|--upload-count count [--upload-hours hours] -d|--download-count count [--download-hours hours] -b|--nas-bridges bridge,bridge -e|--s3-endpoint s3-endpoint-uri -c|--clients client,client [-o|--output-directory path]"
    echo "  -v|--verbose                 verbose"
    echo "  -h|--help                    show this message"
    echo "  -n|--dry-run                 show but do not execute commands"
    echo "  -s|--size size               file size in GB"
    echo "  -u|--upload-count count      number of files to be uploaded"
    echo "     --upload-hours hours      (optional) acceptance criteria for maximum upload duration in hours"
    echo "  -d|--download-count count    number of files to be downloaded"
    echo "     --download-hours hours    (optional) acceptance criteria for maximum download duration in hours"
    echo "  -b|--bridges bridge,bridge   comma separated list of NAS bridges"
    echo "  -e|--s3-endpoint uri         URI of the S3 endpoint consisting of protocol, hostname and port (e.g. https://s3.example.com:8082)"
    echo "  -c|--clients client,client   list of clients to be used for uploading and downloading files"
    echo "  -o|--output-directory path   output directory to be used for storing logfiles and result"
    exit 1
}

function log {
  LOG_DATE=$(date "+%Y-%m-%d-%H:%M:%S")
  LOG_LEVEL=$(printf "%8s" $1)
  LOG_MESSAGE=$2
  echo -e "$LOG_DATE $LOG_LEVEL $LOG_MESSAGE" | tee -a $LOGFILE
}

while true; do
  case "$1" in
    -v | --verbose )          VERBOSE=true; shift ;;
    -h | --help )             HELP=true; shift ;;
    -n | --dry-run )          DRY_RUN=true; shift ;;
    -s | --size )             SIZE="$2"; shift 2 ;;
    -u | --upload-count )     UPLOAD_COUNT="$2"; shift 2 ;;
    --upload-hours )          UPLOAD_HOURS="$2"; shift 2 ;;
    -d | --download-count )   DOWNLOAD_COUNT="$2"; shift 2 ;;
    --download-hours )        DOWNLOAD_HOURS="$2"; shift 2 ;;
    -b | --bridges )          BRIDGES=(${2//,/ }); shift 2 ;;
    -e | --s3-endpoint )      S3_ENDPOINT="$2"; shift 2 ;;
    -c | --clients )          CLIENTS=(${2//,/ }); shift 2 ;;
    -o | --output-directory ) OUTPUT_DIRECTORY="$2"; shift ;;   
    -- ) shift; break ;;
    * ) break ;;
  esac
done

if $HELP;then
  usage
  
  if [ -n "$BRIDGES" ]; then
    echo "This script expects that the clients specified via -c|--clients match the IP/hostname which is exported on the NAS Bridge\n"
  fi
fi

DATE=$(date "+%Y-%m-%d-%H%M")

LOGFILE=$OUTPUT_DIRECTORY/$DATE-performance-acceptance-test.log

log "INFO" "Logfile will be written to $LOGFILE"

CLIENT_COUNT=${#CLIENTS[@]}

UPLOAD_TOTAL_GB=$(($UPLOAD_COUNT * $SIZE))
DOWNLOAD_TOTAL_GB=$(($DOWNLOAD_COUNT * $SIZE))

if ($VERBOSE);then 
  log "VERBOSE" "Verbose: $VERBOSE"
  log "VERBOSE" "Help: $HELP"
  log "VERBOSE" "Dry run: $DRY_RUN"
  log "VERBOSE" "File size: $SIZE"
  log "VERBOSE" "Upload count: $UPLOAD_COUNT"
  log "VERBOSE" "Upload hours: $UPLOAD_HOURS"
  log "VERBOSE" "Upload total GB: ${UPLOAD_TOTAL_GB}GB"
  log "VERBOSE" "Download count: $DOWNLOAD_COUNT"
  log "VERBOSE" "Download total GB: ${DOWNLOAD_TOTAL_GB}GB"
  log "VERBOSE" "Download hours: $DOWNLOAD_HOURS"
  log "VERBOSE" "NAS Bridges: ${BRIDGES[@]}"
  log "VERBOSE" "S3 Endpoint: $S3_ENDPOINT"
  log "VERBOSE" "Clients: ${CLIENTS[@]}"
fi

if [ -n "$BRIDGES" ];then
  NFS_RESULTS=$OUTPUT_DIRECTORY/$DATE-nfs-results.csv
  log "INFO" "Results will be written to $NFS_RESULTS"

  TEST_FOLDER=$DATE-acceptance-tests

  BRIDGE_COUNT=${#BRIDGES[@]}

  if [ $CLIENT_COUNT -lt $BRIDGE_COUNT ]; then
    log "ERROR" "Only ${#CLIENTS[@]} clients specified, but at least $BRIDGE_COUNT required!"
    exit 1
  fi

  NASBRIDGE_MOUNTPOINT=/mnt/nasbridge

  UPLOAD_COUNT_PER_BRIDGE=$(($UPLOAD_COUNT/$BRIDGE_COUNT))
  if [ $UPLOAD_COUNT != $(($UPLOAD_COUNT_PER_BRIDGE*$BRIDGE_COUNT)) ];then
    log "ERROR" "Requested upload count cannot be equally distributed to all NAS Bridges. Please specify an upload count which is a multiple of the number of bridges!"
    exit 1
  fi

  DOWNLOAD_COUNT_PER_BRIDGE=$(($DOWNLOAD_COUNT/$BRIDGE_COUNT))
  if [ $DOWNLOAD_COUNT != $(($DOWNLOAD_COUNT_PER_BRIDGE * $BRIDGE_COUNT)) ];then
    log "ERROR" "Requested download count cannot be equally distributed to all NAS Bridges. Please specify a download count which is a multiple of the number of bridges!"
    exit 1
  fi

  log "INFO" "REQUIREMENT 1: File size is ${SIZE}GB"

  log "INFO" "REQUIREMENT 2: Upload ${UPLOAD_COUNT} files of ${SIZE}GB (${UPLOAD_TOTAL_GB}GB total) in ${UPLOAD_HOURS} hours to each of the ${BRIDGE_COUNT} NAS Bridges"

  log "INFO" "REQUIREMENT 3: Download ${DOWNLOAD_COUNT} files of ${SIZE}GB (${DOWNLOAD_TOTAL_GB}GB total) in ${DOWNLOAD_HOURS} hours from each of the ${BRIDGE_COUNT} NAS Bridges"

  # mount each NAS bridge on all clients
  for i in $(seq 1 $CLIENT_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]} 
    for j in $(seq 1 $BRIDGE_COUNT); do
      BRIDGE=${BRIDGES[$(($j-1))]}
      EXPORT=$(ssh $CLIENT /usr/sbin/showmount -e $BRIDGE | grep / | tail -1 | awk '{ print $1 }')
      MOUNT_EXISTS=$(ssh $CLIENT mount | grep $EXPORT)
      if $DRY_RUN; then
        log "DRY_RUN" "ssh $CLIENT mkdir -p ${NASBRIDGE_MOUNTPOINT}$j/$TEST_FOLDER"
        log "DRY_RUN" "ssh $CLIENT mount -o rw,vers=3,rsize=1048576,wsize=1048576,hard,proto=tcp $BRIDGE:$EXPORT ${NASBRIDGE_MOUNTPOINT}$j/$TEST_FOLDER"
      else
        ssh $CLIENT mkdir -p ${NASBRIDGE_MOUNTPOINT}$j/$TEST_FOLDER
        ssh $CLIENT mount -o rw,vers=3,rsize=1048576,wsize=1048576,hard,proto=tcp $BRIDGE:$EXPORT ${NASBRIDGE_MOUNTPOINT}$j/$TEST_FOLDER
      fi
    done
  done

  log "INFO" "Creating upload script in /tmp/upload-files.sh"

  if ! $DRY_RUN;then
    cat << "EOF" > /tmp/upload-files.sh
#!/bin/bash
UPLOAD_COUNT=$1
UPLOAD_DESTINATION=$2
SIZE=$3
LOGFILE=$4

echo "Upload count: $UPLOAD_COUNT"
echo "Upload start: $UPLOAD_START"
echo "Upload destination: $UPLOAD_DESTINATION"
echo "File size: $SIZE"
echo "Logfile: $LOGFILE"

TIMEFORMAT=%0R
(
  time (
    for COUNT in $(seq -w 1 $UPLOAD_COUNT );do 
      (
        date '+%Y-%m-%d %H:%M:%S'
        set -x
        dd if=/dev/zero of=${UPLOAD_DESTINATION}/${SIZE}g${COUNT} bs=1024k count=${SIZE}k 
        echo "$COUNT files uploaded"
      )
    done 2>&1
    echo "FINISHED"
  )
) &> $LOGFILE
EOF
    chmod 755 /tmp/upload-files.sh
  fi

  log "INFO" "Creating download script in /tmp/download-files.sh"

  if ! $DRY_RUN;then
    cat << "EOF" > /tmp/download-files.sh
#!/bin/bash
DOWNLOAD_COUNT=$1
DOWNLOAD_SOURCE=$2
SIZE=$3
LOGFILE=$4

echo "Download count: $DOWNLOAD_COUNT"
echo "Download source: $DOWNLOAD_SOURCE"
echo "File size: $SIZE"
echo "Logfile: $LOGFILE"

TIMEFORMAT=%0R
(
  while [ -z $FILENAME ];do
    FILENAME=$(find $DOWNLOAD_SOURCE -maxdepth 1 -type f -not -size -${SIZE}G  | shuf -n1)
    sleep 1
  done
  time (
    for COUNT in $(seq -w 1  $DOWNLOAD_COUNT);do 
      (
        unset FILENAME
        while [ -z $FILENAME ];do
          FILENAME=$(find $DOWNLOAD_SOURCE -maxdepth 1 -type f -not -size -${SIZE}G  | shuf -n1)
          sleep 1
        done
        date '+%Y-%m-%d %H:%M:%S'
        set -x
        dd if=$FILENAME of=/dev/null 2>/dev/null
        echo "$COUNT files downloaded"
      )
    done 2>&1
    echo "FINISHED"
  )
) &> $LOGFILE
EOF
    chmod 755 /tmp/download-files.sh
  fi

  log "INFO" "Transferring upload and download script to all clients into the /tmp folder"

  for i in $(seq 1 $CLIENT_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    if $DRY_RUN;then
      log "DRY-RUN" "scp /tmp/upload-files.sh $CLIENT:/tmp/upload-files.sh"
      log "DRY-RUN" "scp /tmp/download-files.sh $CLIENT:/tmp/download-files.sh"
    else
      scp /tmp/upload-files.sh $CLIENT:/tmp/upload-files.sh > /dev/null
      scp /tmp/download-files.sh $CLIENT:/tmp/download-files.sh > /dev/null
    fi
  done

  echo "client,bridge,operation,count,duration (seconds),throughput (MB/s),file size (GB),total (GB)" > $NFS_RESULTS


  log "INFO" "Upload $UPLOAD_COUNT files of size ${SIZE}GB and in parallel download $DOWNLOAD_COUNT files"
  for i in $(seq 1 $BRIDGE_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    BRIDGE=${BRIDGES[$(($i-1))]}
    UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-bridge-$i.log
    log "INFO" "Logfile will be written to client $CLIENT at $UPLOAD_LOGFILE"
    if $DRY_RUN;then
      log "DRY-RUN" "ssh -f $CLIENT \"screen -dm -S upload-bridge-$i /tmp/upload-files.sh $UPLOAD_COUNT_PER_BRIDGE $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER $SIZE $UPLOAD_LOGFILE\""
    else
      ssh -f $CLIENT "screen -dm -S upload-bridge-$i /tmp/upload-files.sh $UPLOAD_COUNT_PER_BRIDGE $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER $SIZE $UPLOAD_LOGFILE"
    fi
  done

  for i in $(seq 1 $BRIDGE_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]} 
    BRIDGE=${BRIDGES[$(($i-1))]}
    DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-bridge-$i.log
    log "INFO" "Logfile will be written to client $CLIENT at $DOWNLOAD_LOGFILE"
    if $DRY_RUN;then
      log "DRY-RUN" "ssh -f $CLIENT \"screen -dm -S download-bridge-$i /tmp/download-files.sh $DOWNLOAD_COUNT_PER_BRIDGE $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER $SIZE $DOWNLOAD_LOGFILE\""
    else
      ssh -f $CLIENT "screen -dm -S download-bridge-$i /tmp/download-files.sh $DOWNLOAD_COUNT_PER_BRIDGE $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER $SIZE $DOWNLOAD_LOGFILE"
    fi
  done

  log "INFO" "regularly check if uploads have completed"
  if ! $DRY_RUN;then
    COMPLETED_COUNT=0
    while [ $COMPLETED_COUNT -lt $(($BRIDGE_COUNT * ($BRIDGE_COUNT + 1) / 2)) ]; do
      COMPLETED_COUNT=0
      sleep 10
      for i in $(seq 1 $BRIDGE_COUNT); do
       CLIENT=${CLIENTS[$(($i-1))]}
       BRIDGE=${BRIDGES[$(($i-1))]}
       UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-bridge-$i.log
       if [[ $(ssh $CLIENT cat $UPLOAD_LOGFILE | grep "FINISHED") == "FINISHED" ]]; then
         COMPLETED_COUNT=$((COMPLETED_COUNT+$i))
         log "INFO" "Upload to bridge $BRIDGE completed"
       fi
      done
    done
  fi

  log "INFO" "regularly check if downloads have completed"
  if ! $DRY_RUN;then
    COMPLETED_COUNT=0
    while [ $COMPLETED_COUNT -lt $(( $BRIDGE_COUNT * ($BRIDGE_COUNT + 1 ) / 2 )) ]; do
      COMPLETED_COUNT=0
      sleep 10
      for i in $(seq 1 $BRIDGE_COUNT); do
        CLIENT=${CLIENTS[$(($i-1))]}
        BRIDGE=${BRIDGES[$(($i-1))]}
        DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-bridge-$i.log
        if [[ $(ssh $CLIENT cat $DOWNLOAD_LOGFILE | grep "FINISHED") == "FINISHED" ]]; then
          COMPLETED_COUNT=$((COMPLETED_COUNT+$i))
          log "INFO" "Download of client $CLIENT from bridge $BRIDGE completed"
        fi
      done
    done
  fi

  log "INFO" "collect upload results"
  if ! $DRY_RUN;then
    for i in $(seq 1 $BRIDGE_COUNT); do
      CLIENT=${CLIENTS[$(($i-1))]}
      BRIDGE=${BRIDGES[$(($i-1))]}
      UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-bridge-$i.log
      DURATION=$(ssh $CLIENT cat $UPLOAD_LOGFILE | tail -1)
      TOTAL=$(($UPLOAD_COUNT_PER_BRIDGE * $SIZE))
      THROUGHPUT=$(echo "scale=3;$TOTAL*1024/$DURATION" | bc)
      echo "$CLIENT,$BRIDGE,upload,$UPLOAD_COUNT_PER_BRIDGE,$DURATION,$THROUGHPUT,$SIZE,$TOTAL" >> $NFS_RESULTS
      log "INFO" "Uploaded $UPLOAD_COUNT_PER_BRIDGE (${TOTAL}GB) files to bridge $BRIDGE in $DURATION seconds with a throughput of $THROUGHPUT MBytes/s"
    done
  fi

  log "INFO" "collect download results"
  if ! $DRY_RUN;then
    for i in $(seq 1 $BRIDGE_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    BRIDGE=${BRIDGES[$(($i-1))]}
    DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-bridge-$i.log
    DURATION=$(ssh $CLIENT cat $DOWNLOAD_LOGFILE | tail -1)
    TOTAL=$(($DOWNLOAD_COUNT_PER_BRIDGE * $SIZE))
    THROUGHPUT=$(echo "scale=3;$TOTAL*1024/$DURATION" | bc)
    echo "$CLIENT,$BRIDGE,download,$DOWNLOAD_COUNT_PER_BRIDGE,$DURATION,$THROUGHPUT,$SIZE,$TOTAL" >> $NFS_RESULTS
    log "INFO" "Downloaded $DOWNLOAD_COUNT_PER_BRIDGE (${TOTAL}GB) files from bridge $BRIDGE in $DURATION seconds with a throughput of $THROUGHPUT MBytes/s"
   done
  fi

  log "INFO" "Deleting files created during test"
  for i in $(seq 1 $BRIDGE_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    BRIDGE=${BRIDGES[$(($i-1))]}
    if $DRY_RUN;then
      log "DRY-RUN" "ssh $CLIENT rm $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER/${SIZE}g*"
      log "DRY-RUN" "ssh $CLIENT rmdir $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER"
    else
      ssh $CLIENT rm $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER/${SIZE}g*
      ssh $CLIENT rmdir $NASBRIDGE_MOUNTPOINT$i/$TEST_FOLDER
    fi
  done

  log "INFO" "Results have been written to $NFS_RESULTS"

  column -s, -t < $NFS_RESULTS
fi

if [ -n "$S3_ENDPOINT" ];then
  TEST_BUCKET=$DATE-acceptance-tests

  S3_RESULTS=$OUTPUT_DIRECTORY/$DATE-s3-results.csv
  log "info" "results will be written to $S3_RESULTS"

  if $DRY_RUN;then
    log "DRY-RUN" "aws s3 mb --endpoint-url $S3_ENDPOINT s3://$TEST_BUCKET"
  else
    aws s3 mb --endpoint-url $S3_ENDPOINT s3://$TEST_BUCKET
  fi

  UPLOAD_COUNT_PER_CLIENT=$(($UPLOAD_COUNT/$CLIENT_COUNT))
  if [ $UPLOAD_COUNT != $(($UPLOAD_COUNT_PER_CLIENT*$CLIENT_COUNT)) ];then
    log "ERROR" "Requested upload count cannot be equally distributed to all clients. Please specify an upload count which is a multiple of the number of clients!"
    exit 1
  fi

  DOWNLOAD_COUNT_PER_CLIENT=$(($DOWNLOAD_COUNT / $CLIENT_COUNT))
  if [ $DOWNLOAD_COUNT != $(($DOWNLOAD_COUNT_PER_CLIENT * $CLIENT_COUNT)) ];then
    log "ERROR" "Requested download count cannot be equally distributed to all clients. Please specify a download count which is a multiple of the number of clients!"
    exit 1
  fi

  log "INFO" "REQUIREMENT 1: Object size is ${SIZE}GB"

  log "INFO" "REQUIREMENT 2: Upload ${UPLOAD_COUNT} objects of ${SIZE}GB (${UPLOAD_TOTAL_GB}GB total) in ${UPLOAD_HOURS} hours to the S3 endpoint ${S3_ENDPOINT}"

  log "INFO" "REQUIREMENT 3: Download ${DOWNLOAD_COUNT} objects of ${SIZE}GB (${DOWNLOAD_TOTAL_GB}GB total) in ${DOWNLOAD_HOURS} hours from S3 endpoint ${S3_ENDPOINT}"

  log "INFO" "Creating upload script in /tmp/upload-object.sh"

  if ! $DRY_RUN;then
    cat << "EOF" > /tmp/upload-objects.sh
#!/bin/bash
UPLOAD_COUNT=$1
UPLOAD_DESTINATION=$2
SIZE=$3
S3_ENDPOINT=$4
LOGFILE=$5

echo "Upload count: $UPLOAD_COUNT"
echo "Upload destination: $UPLOAD_DESTINATION"
echo "Object size: $SIZE"
echo "Logfile: $LOGFILE"

TIMEFORMAT=%0R
(
  time (
    for COUNT in $(seq -w 1 $UPLOAD_COUNT);do 
      (
        date '+%Y-%m-%d %H:%M:%S'
        set -x
        dd if=/dev/zero bs=1024k count=${SIZE}k | aws s3 cp - s3://$UPLOAD_DESTINATION/${SIZE}g${COUNT} --expected-size $(($SIZE * 1024 * 1024 * 1024)) --endpoint-url $S3_ENDPOINT --no-verify-ssl 2>&1 | grep -v InsecureRequestWarning
        echo "$COUNT objects uploaded"
      )
    done 2>&1
    echo "FINISHED"
  )
) &> $LOGFILE
EOF
    chmod 755 /tmp/upload-objects.sh
  fi

  log "INFO" "Creating download script in /tmp/download-objects.sh"

  if ! $DRY_RUN;then
    cat << "EOF" > /tmp/download-objects.sh
#!/bin/bash
DOWNLOAD_COUNT=$1
DOWNLOAD_SOURCE=$2
S3_ENDPOINT=$3
LOGFILE=$4

echo "Download count: $UPLOAD_COUNT"
echo "Download source: $UPLOAD_DESTINATION"
echo "Logfile: $LOGFILE"

TIMEFORMAT=%0R
(
  time (
    for COUNT in $(seq -w 1  $DOWNLOAD_COUNT);do 
      (
        OBJECT=$(aws s3 ls $DOWNLOAD_SOURCE --endpoint-url $S3_ENDPOINT --no-verify-ssl 2>/dev/null | awk '{print $4}'  | shuf -n1)
        date '+%Y-%m-%d %H:%M:%S'
        set -x
        aws s3 cp s3://$DOWNLOAD_SOURCE/$OBJECT - --endpoint-url $S3_ENDPOINT --no-verify-ssl 2>&1 > /dev/null | tee | grep -v InsecureRequestWarning
        echo "$COUNT objects downloaded"
      )
    done 2>&1
    echo "FINISHED"
  )
) &> $LOGFILE
EOF
    chmod 755 /tmp/download-objects.sh
  fi

  log "INFO" "Transferring upload and download script to all clients into the /tmp folder"

  for i in $(seq 1 $CLIENT_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    if $DRY_RUN;then
      log "DRY-RUN" "scp /tmp/upload-objects.sh $CLIENT:/tmp/upload-objects.sh"
      log "DRY-RUN" "scp /tmp/download-objects.sh $CLIENT:/tmp/download-objects.sh"
    else
      scp /tmp/upload-objects.sh $CLIENT:/tmp/upload-objects.sh > /dev/null
      scp /tmp/download-objects.sh $CLIENT:/tmp/download-objects.sh > /dev/null
    fi
  done

  echo "client,operation,count,duration (seconds),throughput (MB/s),object size (GB),total (GB)" > $S3_RESULTS

  if [ $UPLOAD_DOWNLOAD_DIFFERENCE_COUNT -gt 0 ];then
    log "INFO" "INITIALIZATION: upload difference of ${UPLOAD_DOWNLOAD_DIFFERENCE_COUNT} objects S3 endpoint"
    for i in $(seq 1 $CLIENT_COUNT); do
      CLIENT=${CLIENTS[$(($i-1))]}
      UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-download-difference-client-$i.log
      log "INFO" "Logfile will be written to client $CLIENT at $UPLOAD_LOGFILE"
      if $DRY_RUN;then
        log "DRY-RUN" "ssh -f $CLIENT \"screen -dm -S upload-download-difference-client-$i /tmp/upload-objects.sh $UPLOAD_DOWNLOAD_DIFFERENCE_COUNT_PER_CLIENT $TEST_BUCKET $SIZE $S3_ENDPOINT $UPLOAD_LOGFILE\""
      else
        ssh -f $CLIENT "screen -dm -S upload-download-difference-client-$i /tmp/upload-objects.sh $UPLOAD_DOWNLOAD_DIFFERENCE_COUNT_PER_CLIENT $TEST_BUCKET $SIZE $S3_ENDPOINT $UPLOAD_LOGFILE"
      fi
    done

    log "INFO" "regularly check if upload has completed"
    if ! $DRY_RUN;then
      COMPLETED_COUNT=0
      while [ $COMPLETED_COUNT -lt $CLIENT_COUNT ]; do
        COMPLETED_COUNT=0
        sleep 10
        for i in $(seq 1 $CLIENT_COUNT); do
          CLIENT=${CLIENTS[$(($i-1))]}
          UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-download-difference-client-$i.log
          if [[ $(ssh $CLIENT cat $UPLOAD_LOGFILE | grep "FINISHED") == "FINISHED" ]]; then
            COMPLETED_COUNT=$((COMPLETED_COUNT+1))
            log "INFO" "Upload to bridge $BRIDGE completed"
          fi
       done
     done
    fi

    log "INFO" "collect results"
    if ! $DRY_RUN;then
     for i in $(seq 1 $CLIENT_COUNT); do
       CLIENT=${CLIENTS[$(($i-1))]}
       UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-download-difference-client-$i.log
       DURATION=$(ssh $CLIENT cat $UPLOAD_LOGFILE | tail -1)
       TOTAL=$(($UPLOAD_DOWNLOAD_DIFFERENCE_COUNT_PER_CLIENT * $SIZE))
       THROUGHPUT=$(echo "scale=3;$TOTAL*1024/$DURATION" | bc)
       echo "$CLIENT,$BRIDGE,upload,$UPLOAD_DOWNLOAD_DIFFERENCE_COUNT_PER_CLIENT,$DURATION,$THROUGHPUT,$SIZE,$TOTAL" >> $S3_RESULTS
       log "INFO" "Uploaded $UPLOAD_DOWNLOAD_DIFFERENCE_COUNT_PER_CLIENT (${TOTAL}GB) files to bridge $BRIDGE in $DURATION seconds with a throughput of $THROUGHPUT MBytes/s"
     done
    fi
  fi

  log "INFO" "RUN: Upload $UPLOAD_COUNT objects of size ${SIZE}GB and in parallel download $DOWNLOAD_COUNT files"
  for i in $(seq 1 $CLIENT_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]}
    UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-client-$i.log
    log "INFO" "Logfile will be written to client $CLIENT at $UPLOAD_LOGFILE"
    if $DRY_RUN;then
      log "DRY-RUN" "ssh -f $CLIENT \"screen -dm -S upload-client-$i /tmp/upload-objects.sh $UPLOAD_COUNT_PER_CLIENT $TEST_BUCKET $SIZE $S3_ENDPOINT $UPLOAD_LOGFILE\""
    else
      ssh -f $CLIENT "screen -dm -S upload-client-$i /tmp/upload-objects.sh $UPLOAD_COUNT_PER_CLIENT $TEST_BUCKET $SIZE $S3_ENDPOINT $UPLOAD_LOGFILE"
    fi
  done

  for i in $(seq 1 $CLIENT_COUNT); do
    CLIENT=${CLIENTS[$(($i-1))]} 
    DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-client-$i.log
    log "INFO" "Logfile will be written to client $CLIENT at $DOWNLOAD_LOGFILE"
    if $DRY_RUN;then
      log "DRY-RUN" "ssh -f $CLIENT \"screen -dm -S download-client-$i /tmp/download-objects.sh $DOWNLOAD_COUNT_PER_CLIENT $TEST_BUCKET $S3_ENDPOINT $DOWNLOAD_LOGFILE\""
    else
      ssh -f $CLIENT "screen -dm -S download-client-$i /tmp/download-objects.sh $DOWNLOAD_COUNT_PER_CLIENT $TEST_BUCKET $S3_ENDPOINT $DOWNLOAD_LOGFILE"
    fi
  done


  log "INFO" "regularly check if uploads have completed"
  if ! $DRY_RUN;then
    COMPLETED_COUNT=0
    while [ $COMPLETED_COUNT -lt $CLIENT_COUNT ]; do
      COMPLETED_COUNT=0
      sleep 10
      for i in $(seq 1 $CLIENT_COUNT); do
        CLIENT=${CLIENTS[$(($i-1))]}
        UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-client-$i.log
        if [[ $(ssh $CLIENT cat $UPLOAD_LOGFILE | grep "FINISHED") == "FINISHED" ]]; then
         COMPLETED_COUNT=$((COMPLETED_COUNT+1))
         log "INFO" "Upload to S3 endpoint $S3_ENDPOINT completed"
        fi
      done
    done
  fi

  log "INFO" "regularly check if downloads have completed"
  if ! $DRY_RUN;then
    COMPLETED_COUNT=0
    while [ $COMPLETED_COUNT -lt $CLIENT_COUNT ]; do
      COMPLETED_COUNT=0
      for i in $(seq 1 $CLIENT_COUNT); do
        CLIENT=${CLIENTS[$(($i-1))]}
        DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-client-$i.log
        if [[ $(ssh $CLIENT cat $DOWNLOAD_LOGFILE | grep "FINISHED") == "FINISHED" ]]; then
          COMPLETED_COUNT=$((COMPLETED_COUNT+1))
          log "INFO" "Download of client $CLIENT completed"
        fi
      done
    done
  fi

  log "INFO" "collect upload results"
  if ! $DRY_RUN;then
    for i in $(seq 1 $CLIENT_COUNT); do
      CLIENT=${CLIENTS[$(($i-1))]}
      UPLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-upload-client-$i.log
      DURATION=$(ssh $CLIENT cat $UPLOAD_LOGFILE | tail -1)
      TOTAL=$(($UPLOAD_COUNT_PER_CLIENT * $SIZE))
      THROUGHPUT=$(echo "scale=3;$TOTAL*1024/$DURATION" | bc)
      echo "$CLIENT,upload,$UPLOAD_COUNT_PER_CLIENT,$DURATION,$THROUGHPUT,$SIZE,$TOTAL" >> $S3_RESULTS
      log "INFO" "Uploaded $UPLOAD_COUNT_PER_CLIENT (${TOTAL}GB) objects to S3 endpoint $S3_ENDPOINT in $DURATION seconds with a throughput of $THROUGHPUT MBytes/s"
    done
  fi

  log "INFO" "collect download results"
  if ! $DRY_RUN;then
    for i in $(seq 1 $CLIENT_COUNT); do
      CLIENT=${CLIENTS[$(($i-1))]}
      DOWNLOAD_LOGFILE=$OUTPUT_DIRECTORY/$DATE-download-client-$i.log
      DURATION=$(ssh $CLIENT cat $DOWNLOAD_LOGFILE | tail -1)
      TOTAL=$(($DOWNLOAD_COUNT_PER_CLIENT * $SIZE))
      THROUGHPUT=$(echo "scale=3;$TOTAL*1024/$DURATION" | bc)
      echo "$CLIENT,download,$DOWNLOAD_COUNT_PER_CLIENT,$DURATION,$THROUGHPUT,$SIZE,$TOTAL" >> $S3_RESULTS
      log "INFO" "Downloaded $DOWNLOAD_COUNT_PER_CLIENT (${TOTAL}GB) objects from S3 endpoint $S3_ENDPOINT in $DURATION seconds with a throughput of $THROUGHPUT MBytes/s"
   done
  fi

  log "INFO" "Deleting objects and bucket created during test"
  if $DRY_RUN;then
    log "DRY-RUN" "aws s3 rb --endpoint-url $S3_ENDPOINT --force s3://$TEST_BUCKET"
  else
    aws s3 rb --endpoint-url $S3_ENDPOINT --force s3://$TEST_BUCKET
  fi

  log "INFO" "Results have been written to $S3_RESULTS"

  column -s, -t < $S3_RESULTS
fi
