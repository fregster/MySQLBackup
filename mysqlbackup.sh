#!/bin/bash

# MySQL More Advanced Backups
#
# Script written by Paul Fryer based on a script I found on the Internet but I can not find out where, although very little of the original script is left!
#
# Semi useful features:
#   Diff based de-duplication
#   Parrell backups to reduce backup time (Based on the number of CPU's, defaults to 2)
#
# Free for anyone's use and is not covered by any licence or waranty etc be aware it may eat your computer
#
# TODO:
#   Add command line options, username, password, databases, disable diffs, force running (Ignore pid locks), start delay, per database delay, debug output, output directory, config file
#   Logging functions with verbosity settings
#   Update if's to allow for better bool checking
#   Split up into functions more for easier reading

#set -x

TIME_1=`date +%s`
SCRIPT_NAME='MYSQL MAB'

#Options change these as required
#Change this only if you do not wish to use the .my.cnf file or the get opts
DB_DEFINE_USER_DETAILS=no
DB_USER=root
DB_PASSWORD=password
DB_HOST=localhost

#One day is 1440 mins
BACKUP_LIFE="+1470"
BACKUP_FILE_MAX="+4920"

#Compression methods
#Strongly recomend this is left as gzip due to the use of the z tools
COMPRESS_EACH_BACKUP=true
COMPRESS_COMMAND=gzip
COMPRESS_EXT=".gz"
COMPRESS_EXPAND=zcat
#COMPRESS_COMMAND=bzip2
#COMPRESS_EXT=".bz2"

#INCREMENTAL_BACKUPS
INCREMENTAL_BACKUPS=true
INCREMENTAL_MIN_SIZE=125000
INCREMENTAL_BACKUPS_MAX_FULL_LIFE="-120"
INCREMENTAL_DIFF_CMD='diff -u --speed-large-files '

#Storage options
DIR=/backups
LOG=/var/log/mysql-backups.log
CHMOD=640

#Use this to create a seperate directory for each database this allows for seperate folder permissions etc to be kept 
USE_SEPERATE_DIRS=true

#Misc options
DELAY_START=1
DELAY_BACKUPS=1

### START LOGIC ###

PID=/var/run/mysqlbackup.pid

NUMBER_OF_CPUS=`grep -c ^processor /proc/cpuinfo`
re='^[0-9]+$'
if ! [[ $NUMBER_OF_CPUS =~ $re ]] ; then
    NUMBER_OF_CPUS=2
fi


# create empty lock file if none exists
cat /dev/null >> $PID
read lastPID < $PID

# if lastPID is not null and a process with that pid exists , exit
[ ! -z "$lastPID" -a -d /proc/$lastPID ] && exit

echo "Starting ${SCRIPT_NAME} with pid $$"  >> $LOG
# save the current pid in the lock file
echo $$ > $PID

if [ ! -d "$DIR" ]; then
    # Control will enter here if the database backup dir doesn't exist
    echo "Creating database backup parent directory $DIR" >> $LOG
    mkdir -p $DIR
fi
cd $DIR

echo "A ${SCRIPT_NAME} with a start delay of $DELAY_START seconds has started at $(date +%H%M)" >> $LOG
sleep $DELAY_START

echo "${SCRIPT_NAME} for $(date +%m-%d-%y) at $(date +%H%M) is now running" >> $LOG

MYSQL_CONNECTION_STRING=''
if [ $DB_DEFINE_USER_DETAILS = true ]; then
    MYSQL_CONNECTION_STRING="--user=$DB_USER --password=$DB_PASSWORD -h $DB_HOST"
fi

#Add if in here to allow a comma separated list of databases via options.
DBS="$(mysql $MYSQL_CONNECTION_STRING -h $DB_HOST -Bse 'show databases')"


backup_mysql_database(){

#Debug to stderror
#echo "Backing up ${db}" 1>&2

    #File nameing format
    #This is in the loop so the hours and minutes is correct if the database backups are large
    FILE_DATE=$(date +%y-%m-%d-%H%M)

    #0 = not yet enabled
    #-1 = force disabled
    #1 = all checks passed and now enabled
    DO_DIFF=0

    db_dir=$DIR
    if [ $USE_SEPERATE_DIRS = true ]; then
        db_dir=$DIR/$db
    fi

    if [ ! -d "$db_dir" ]; then
        # Control will enter here if the database backup dir doesn't exist
        echo "Creating database backup directory $db_dir" >> $LOG
        DO_DIFF=-1
        mkdir $db_dir
    fi

    db_file=${db}-$FILE_DATE.sql
    COMPRESS_COMMAND_TO_USE=''
    if [ $COMPRESS_EACH_BACKUP = true ]; then
        db_file=${db_file}${COMPRESS_EXT}
        COMPRESS_COMMAND_TO_USE=" ${COMPRESS_COMMAND} -c "
    fi

    echo "$db_file is being saved in $db_dir" >> $LOG
    # remember to add the options you need with your backups here.
    EXTRA_FLAGS=""
    if [ $db == "mysql" ]; then
        EXTRA_FLAGS="$EXTRA_FLAGS --events"
    fi

    if [ $INCREMENTAL_BACKUPS = true ]  && [ "$DO_DIFF" = "0" ]; then
        LATEST_FULL_BACKUP=`ls -t $db_dir/*.sql.gz | cut -f1 | head -n 1`
    DO_DIFF=`find "$LATEST_FULL_BACKUP" -mmin $INCREMENTAL_BACKUPS_MAX_FULL_LIFE | wc -l`

    if [ "$DO_DIFF" = "1" ]; then
        LATEST_FULL_BACKUP_SIZE=`stat -c %s "$LATEST_FULL_BACKUP"`
        if [ $LATEST_FULL_BACKUP_SIZE -le $INCREMENTAL_MIN_SIZE ]; then
            DO_DIFF=0
        fi
    fi
fi

    MYSQL_BACKUP_COMMAND="mysqldump $MYSQL_CONNECTION_STRING $db --single-transaction -R $EXTRA_FLAGS"

    BACKUP_FILE=$db_dir/$db_file
    if [ "$DO_DIFF" = "1" ]; then
        BACKUP_FILE=`echo ${LATEST_FULL_BACKUP//$COMPRESS_EXT/}`-$FILE_DATE.diff${COMPRESS_EXT}

        echo "Running diff backup to file $BACKUP_FILE" >> $LOG
        $INCREMENTAL_DIFF_CMD <($COMPRESS_EXPAND $LATEST_FULL_BACKUP) <($MYSQL_BACKUP_COMMAND) | ${COMPRESS_COMMAND_TO_USE} > $BACKUP_FILE
    else
        echo "Running full backup" >> $LOG
        $MYSQL_BACKUP_COMMAND | $COMPRESS_COMMAND_TO_USE > $BACKUP_FILE
    fi

    chmod $CHMOD $BACKUP_FILE

    echo "Database backup completed" >> $LOG
    echo "" >> $LOG

#Debug to stderror
#echo "Completed backing up ${db}" 1>&2


}


## Main process loop
JOBS_RUNNING=0
NUMBER_OF_CPUS+=1
for db in ${DBS[@]}
do
    if [ ${JOBS_RUNNING} -lt ${NUMBER_OF_CPUS} ]; then
	JOBS_RUNNING+=1

        backup_mysql_database &

        #A per database delay to allow for IO sync's before the next backup
        sleep $DELAY_BACKUPS
    else
	wait
    fi
done
wait

## This is just a sanity log check
TIME_2=`date +%s`
elapsed_time=$(( ( $TIME_2 - $TIME_1 ) / 60 ))
echo "This ${SCRIPT_NAME} ran for a total of $elapsed_time minutes using ${NUMBER_OF_CPUS} threads." >> $LOG

# Delete any old databases.
for del in $(`find $DIR -name "*.sql${COMPRESS_EXT}" -mmin +2160`)
do
	echo "This backup is more than ${BACKUP_LIFE} mins old and it is being background deleted: $del" >> $LOG
	rm -f $del &
	if [ $INCREMENTAL_BACKUPS = true ]; then
		BACKUP_DIFFS=`echo ${del//$COMPRESS_EXT/}`
		rm -f $BACKUP_DIFFS.*.diff* &
	fi
done

# Check for any other sql dumps that have been left and delete after BACKUP_LIFE_MAX
for del in $(find $DIR -name '*.sql' -mmin +4920)
do
	echo "This backup is more than ${BACKUP_LIFE_MAX} mins old and it is being background deleted: $del" >> $LOG
	rm -f $del &
done

echo "---------- END ----------" >> $LOG
echo "" >>$LOG

#Blank the PID file
cat /dev/null >> $PID