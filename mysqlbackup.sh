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

TIME_1=`date +%s`
SCRIPT_NAME='MYSQL MAB'
SCRIPT_NAME_SHORT='mab'

#Defaults
#Options change these as required with the params
#Change this only if you do not wish to use the .my.cnf file or the get opts
MYCNF='/root/.my.cnf'
DB_DEFINE_USER_DETAILS=no
COMPRESS_EACH_BACKUP=true
INCREMENTAL_BACKUPS=false
DATE_STAMP_FILES=false
FORCE_EXTENDED_INSERT=true
DB_HOST=''

#Storage options
DIR="/home/${SCRIPT_NAME_SHORT}"
LOG=/var/log/mysql-backups.log
CHMOD=640

#Use this to create a seperate directory for each database this allows for seperate folder permissions etc to be kept 
USE_SEPERATE_DIRS=true

while getopts ":c:u:p:h:d:l:esitvz" o; do
    case "${o}" in
    	c)
			echo "MySQL Config File : $OPTARG" >&2
			MYCNF=$OPTARG
            ;;
        e)
        	echo "Disable extended inserts" >&2
        	FORCE_EXTENDED_INSERT=false
        	;;
        u)
			echo "MySQL User : $OPTARG" >&2
			DB_USER=$OPTARG
			DB_DEFINE_USER_DETAILS=yes
            ;;

        p)
			echo "MySQL Password : $OPTARG" >&2
			DB_PASSWORD=$OPTARG
			DB_DEFINE_USER_DETAILS=yes
            ;;
        h)
			echo "MySQL Hostname FQDN: $OPTARG" >&2
			DB_HOST="-h $OPTARG"
            ;;
        z)
			echo "Disable GZIP backups : $OPTARG" >&2
			COMPRESS_EACH_BACKUP=false
            ;;
        i)
			echo "Enable incremental backups : $OPTARG" >&2
			INCREMENTAL_BACKUPS=true
            ;;
        d)
			echo "Backup dir : $OPTARG" >&2
			DIR=$OPTARG
            ;;
        l)
			echo "Backup Log file : $OPTARG" >&2
			LOG=$OPTARG
            ;;
        s)
        	echo "Use separate director for each database backed up : $OPTARG" >&2
        	USE_SEPERATE_DIRS=enable
        	;;
        t)
        	echo "Date and TimeStamp filenames : $OPTARG" >&2
        	DATE_STAMP_FILES=true
        	;;
        v)
			echo "Verbose debugging : $OPTARG" >&2
			set -x
            ;;
	esac
done
shift $((OPTIND-1))

#One day is 1440 mins
BACKUP_LIFE="+1470"
BACKUP_FILE_MAX="+4920"

#Compression methods
#Strongly recomend this is left as gzip due to the use of the z tools
COMPRESS_COMMAND=gzip
COMPRESS_EXT=".gz"
COMPRESS_EXPAND=zcat
#COMPRESS_COMMAND=bzip2
#COMPRESS_EXT=".bz2"

#INCREMENTAL_BACKUPS
INCREMENTAL_MIN_SIZE=125000
INCREMENTAL_BACKUPS_MAX_FULL_LIFE="-120"

#Misc options
DELAY_START=0
DELAY_BACKUPS=1

### START LOGIC ###

PID=/var/run/mysqlbackup.pid

NUMBER_OF_CPUS=`grep -c ^processor /proc/cpuinfo`
re='^[0-9]+$'
if ! [[ $NUMBER_OF_CPUS =~ $re ]] ; then
    NUMBER_OF_CPUS=1
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

echo "${SCRIPT_NAME} for $(date +%m-%d-%y) at $(date +%H%M) is now running with upto ${NUMBER_OF_CPUS} threads." >> $LOG
echo "" >> $LOG

MYSQL_CONNECTION_STRING=''
if [ $DB_DEFINE_USER_DETAILS = true ]; then
    MYSQL_CONNECTION_STRING="--user=$DB_USER --password=$DB_PASSWORD -h $DB_HOST"
fi

#Add if in here to allow a comma separated list of databases via options.
DBS="$(mysql $MYSQL_CONNECTION_STRING $DB_HOST -Bse 'show databases')"
echo "Found the following databases for backup:" >> $LOG
echo "$DBS" >> $LOG
echo "" >> $LOG


#The main database backup function
backup_mysql_database(){

    #Bump the running jobs counter
    ((JOBS_RUNNING++))
#Debug to stderror
#echo "Backing up ${db}" 1>&2


    #File nameing format
    #This is in the loop so the hours and minutes is correct if the database backups are large
    FILE_DATE=$(date +%y-%m-%d-%H%M)
    BACKUP_RUN_TIME_START=`date +%s`

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

    #Create the file name with or with out the date stamp
    if [ $DATE_STAMP_FILES = true ]; then
    	db_file=${db}-$FILE_DATE.sql
    else
    	db_file=${db}.sql
    fi
    
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

	if [ $INCREMENTAL_BACKUPS = true ]  || [ "$FORCE_EXTENDED_INSERT" = true ]; then
		#We need to enable extended inserts to allow for decent diffing of a file
		#For many remote backup soloutions this will speed up the remote copy off too but delay the restore time
    	EXTRA_FLAGS="$EXTRA_FLAGS --extended-insert=FALSE --quick"
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
             echo "    Running diff backup to file $BACKUP_FILE" >> $LOG

        #Check if we can use the more advanced rdiff over diff
#if [ hash rdiff 2>/dev/null ]; then
            #            INCREMENTAL_DIFF_CMD='rdiff signature - '
            #INCREMENTAL_EXT='.rdiff'
            #BACKUP_FILE=`echo ${LATEST_FULL_BACKUP//$COMPRESS_EXT/}`-$FILE_DATE${INCREMENTAL_EXT}${COMPRESS_EXT}
            #RDIFF_RUN_SIG="rdiff signature - $BACKUP_FILE.sig <($COMPRESS_EXPAND $LATEST_FULL_BACKUP)"
            #RDIFF_RUN_DELTA="rdiff delta $BACKUP_FILE.sig - - <($MYSQL_BACKUP_COMMAND) | ${COMPRESS_COMMAND_TO_USE} > $BACKUP_FILE"

            #`$RDIFF_RUN_SIG && $RDIFF_RUN_DELTA`


#       else
			#Diff has memory issues with really, really big files. RDiff is better from Rsync but it's a bit of a pain to setup see above
           INCREMENTAL_DIFF_CMD='diff -u --speed-large-files '
           INCREMENTAL_EXT='.diff'
           BACKUP_FILE=`echo ${LATEST_FULL_BACKUP//$COMPRESS_EXT/}`-$FILE_DATE${INCREMENTAL_EXT}${COMPRESS_EXT}
           $INCREMENTAL_DIFF_CMD <($COMPRESS_EXPAND $LATEST_FULL_BACKUP) <($MYSQL_BACKUP_COMMAND) | ${COMPRESS_COMMAND_TO_USE} > $BACKUP_FILE
#       fi





    else
        echo "    Running full backup of '${db}'" >> $LOG
        $MYSQL_BACKUP_COMMAND | $COMPRESS_COMMAND_TO_USE > $BACKUP_FILE
    fi

    chmod $CHMOD $BACKUP_FILE

    BACKUP_RUN_TIME_END=`date +%s`
    BACKUP_RUN_TIME=$(( ( $BACKUP_RUN_TIME_END - $BACKUP_RUN_TIME_START ) ))
    echo "    Database backup of '${db}' completed in ${BACKUP_RUN_TIME} seconds" >> $LOG

#Debug to stderror
#echo "Completed backing up ${db}, sleeping processes for $DELAY_BACKUPS seconds" 1>&2

    #A per database delay to allow for IO sync's before the next backup
    sleep $DELAY_BACKUPS

    #Reduce the running jobs counter
    ((JOBS_RUNNING--))
}


## Main process loop
JOBS_RUNNING=0
((NUMBER_OF_CPUS++))
for db in ${DBS[@]}
do
    if [ ${JOBS_RUNNING} -ge ${NUMBER_OF_CPUS} ]; then
        echo "Max jobs running, issuing wait" >> $LOG
        wait
    fi

    backup_mysql_database &

done
wait

## This is just a sanity log check
TIME_2=`date +%s`
elapsed_time=$(( ( $TIME_2 - $TIME_1 ) / 60 ))
echo "" >>$LOG
echo "This ${SCRIPT_NAME} ran for a total of $elapsed_time minutes." >> $LOG

# Delete any old databases.
for del in $(`find $DIR -name "*.sql${COMPRESS_EXT}" -mmin +2160`)
do
	echo "This backup is more than ${BACKUP_LIFE} mins old and it is being background deleted: $del" >> $LOG
	rm -f $del &
	if [ $INCREMENTAL_BACKUPS = true ]; then
		BACKUP_DIFFS=`echo ${del//$COMPRESS_EXT/}`
		rm -f $BACKUP_DIFFS.*diff* &
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