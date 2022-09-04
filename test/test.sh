#!/bin/bash
#
# This script does some testing with atftp server and client
#
# It needs ~150MB free diskspace in $TEMPDIR

set -e

# assume we are called in the source tree after the build
# so binaries are one dir up
ATFTP=../atftp
ATFTPD=../atftpd
for EX in ATFTP ATFTPD ; do
    if [[ ! -x ${!EX} ]] ; then
        cmd=$(basename ${!EX})
        eval $EX="$(command -v $cmd)"
        echo "Using installed $cmd binary."
    else
        echo "Using $cmd from build directory."
    fi
done

# set some default values for variables used in this script
# if the variables are already set when this script is started
# those values are used
#

: ${HOST:=127.0.0.1}
: ${PORT:=2001}
: ${TEMPDIR:="/tmp"}

# Number of parallel clients for high server load test
: ${NBSERVER:=200}

# Some Tests need root access (e.g. to mount a tempfs filesystem)
# and need sudo for this, so maybe the script asks for a password
#
# if these tests should be performed then start test.sh like this:
#   WANT_INTERACTIVE_TESTS=yes ./test.sh
: ${WANT_INTERACTIVE_TESTS:=no}

# When the Tests have been run, should the files be cleaned up?
# defaults to yes, if you need test output for troubleshooting either set the
# environment variable CLEANUP=0
#   or
# call test.sh with parameter "--nocleanup" (for backward compatibility)
: ${CLEANUP:=1}
if [ "$1" == "--nocleanup" ]; then
	CLEANUP=0
fi

#####################################################################################
DIRECTORY=$(mktemp -d ${TEMPDIR}/atftp-test.XXXXXX)
SERVER_ARGS="--daemon --no-fork --logfile=/dev/stdout --port=$PORT --verbose=6 $DIRECTORY"
SERVER_LOG=./atftpd.log

ERROR=0

function start_server() {
	# start a server
	echo -n "Starting atftpd server on port $PORT: "
	$ATFTPD  $SERVER_ARGS > $SERVER_LOG &
	if [ $? != 0 ]; then
		echo "Error starting server"
		exit 1
	fi
	sleep 1
	ATFTPD_PID=$!
	# test if server process exists
	ps -p $ATFTPD_PID >/dev/null 2>&1
	if [ $? != 0 ]; then
		echo "server process died"
		exit 1
	fi
	echo "PID $ATFTPD_PID"
}

function stop_server() {
	echo "Stopping atftpd server"
	kill $ATFTPD_PID
}


function check_file() {
	if cmp $1 $2 2>/dev/null ; then
		echo "OK"
	else
		echo "ERROR - $1 $2 not equal"
		ERROR=1
	fi
}

function check_trace() {
    local LOG="$1" FILE="$2"
    local oack tsize wsize bsize c d e
    oack=$(grep "OACK" "$LOG")
    tsize=$(echo $oack | sed -nE "s/.*tsize: ([0-9]+).*/\1/p")
    wsize=$(echo $oack | sed -nE "s/.*windowsize: ([0-9]+).*/\1/p")
    bsize=$(echo $oack | sed -nE "s/.*blksize: ([0-9]+).*/\1/p")
    c=$(grep -E "DATA <block:" "$LOG" | wc -l)
    d=$(grep "ACK <block:" "$LOG" | wc -l)
    e=$(grep "sent ACK <block: 0>" "$LOG" | wc -l)
    ## defaults, if not found in OACK:
    : ${tsize:=$(ls -l $FILE | cut -d ' ' -f5)}
    : ${wsize:=1}
    : ${bsize:=512}
    ## e is for the ACK of the OACK
    ## the +1 is the last block, it might be empty and ist ACK'd:
    if [[ $((tsize/bsize + 1)) -ne $c ]] || \
           [[ $((tsize/(bsize*wsize) + 1 + e)) -ne $d ]] ; then
        echo -e "\nERROR: expected blocks: $((tsize/bsize + 1)), received/sent blocks: $c"
        echo "ERROR: expected ACKs: $((tsize/(bsize*wsize) + 1)), sent/received ACKs: $((d-e))"
        ERROR=1
    else
        echo -n "$c blocks, $((d-e)) ACKs → "
    fi
}

function test_get_put() {
    local FILE="$1"
    shift
    echo -n " get, ${FILE} ($@) ... "
    if [[ $@ == *--trace* ]] ; then
        stdout="$DIRECTORY/$WRITE.stdout"
    else
        stdout="/dev/null"
    fi
    $ATFTP "$@" --get --remote-file ${FILE} \
           --local-file out.bin $HOST $PORT 2> $stdout
    if [[ -f "$stdout" ]] ;  then
        check_trace "$stdout"
    fi
    check_file $DIRECTORY/${FILE} out.bin

    echo -n " put, ${FILE} ($@) ... "
    $ATFTP "$@" --put --remote-file $WRITE \
           --local-file $DIRECTORY/${FILE} $HOST $PORT 2> $stdout
    if [[ -f "$stdout" ]] ;  then
        check_trace "$stdout" "$DIRECTORY/${FILE}"
    fi
    # wait a second because in some case the server may not have time
    # to close the file before the file compare:
    # sleep ## is this still needed?
    check_file $DIRECTORY/${FILE} $DIRECTORY/$WRITE
    rm -f "$DIRECTORY/$WRITE" "$DIRECTORY/$WRITE.stdout" out.bin
}

# make sure we have /tftpboot with some files
if [ ! -d $DIRECTORY ]; then
	echo "create $DIRECTORY before running this test"
	exit 1
fi
echo "Using directory $DIRECTORY for test files"
echo "Work directory " $(pwd)

# files needed
READ_0=READ_0.bin
READ_511=READ_511.bin
READ_512=READ_512.bin
READ_2K=READ_2K.bin
READ_BIG=READ_BIG.bin
READ_128K=READ_128K.bin
READ_1M=READ_1M.bin
READ_10M=READ_10M.bin
READ_101M=READ_101M.bin
WRITE=write.bin

echo -n "Creating test files ... "
touch $DIRECTORY/$READ_0
touch $DIRECTORY/$WRITE; chmod a+w $DIRECTORY/$WRITE
dd if=/dev/urandom of=$DIRECTORY/$READ_511 bs=1 count=511 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_512 bs=1 count=512 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_2K bs=1 count=2048 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_BIG bs=1 count=51111 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_128K bs=1K count=128 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_1M bs=1M count=1 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_10M bs=1M count=10 2>/dev/null
dd if=/dev/urandom of=$DIRECTORY/$READ_101M bs=1M count=101 2>/dev/null
echo "done"

start_server
trap stop_server EXIT SIGINT SIGTERM

#
# test get and put
#
echo "Testing get and put with standard options"
test_get_put $READ_0
test_get_put $READ_511
test_get_put $READ_512
test_get_put $READ_2K
test_get_put $READ_BIG
test_get_put $READ_128K
test_get_put $READ_1M
test_get_put $READ_101M

echo
echo "Testing get and put with misc blocksizes"
test_get_put $READ_BIG --option "blksize 8"
test_get_put $READ_BIG --option "blksize 256"
test_get_put $READ_1M --option "blksize 1428"
test_get_put $READ_1M --option "blksize 1533"
test_get_put $READ_1M --option "blksize 16000"
test_get_put $READ_1M --option "blksize 40000"
test_get_put $READ_1M --option "blksize 65464"
#
echo
echo "Testing get and put with misc windowsizes"
## use some options here to allow trace analysis:
test_get_put $READ_2K --option "windowsize 1" --option "tsize 0" --option "blksize 1024" --trace
test_get_put $READ_2K --option "windowsize 2" --option "tsize 0" --option "blksize 512" --trace
test_get_put $READ_2K --option "windowsize 4" --option "tsize 0" --option "blksize 256" --trace
test_get_put $READ_128K --option "windowsize 8" --option "tsize 0" --option "blksize 1024" --trace
test_get_put $READ_128K --option "windowsize 16" --option "tsize 0" --option "blksize 512" --trace
test_get_put $READ_101M --option "windowsize 32" --option "tsize 0" --option "blksize 1428" --trace
test_get_put $READ_1M --option "windowsize 5" --option "tsize 0" --option "blksize 1428" --trace

echo
echo "Testing large file with small blocksize so block numbers will wrap over 65536"
test_get_put $READ_1M --option "blksize 8" --trace

#
# testing for invalid file name
#
OUTPUTFILE="01-out"
echo
echo -n "Test detection of non-existing file name ... "
set +e
$ATFTP --trace --get -r "thisfiledoesntexist" -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
set -e
if grep -q "<File not found>" "$OUTPUTFILE"; then
	echo OK
else
	echo ERROR
	ERROR=1
fi

#
# testing for invalid blocksize
# maximum blocksize is 65464 as described in RCF2348
#
OUTPUTFILE="02-out"
echo
echo "Testing blksize option ..."
echo -n " smaller than minimum ... "
set +e
$ATFTP --option "blksize 7" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
set -e
if grep -q "<Failure to negotiate RFC2347 options>" "$OUTPUTFILE"; then
	echo OK
else
	echo ERROR
	ERROR=1
fi
echo -n " bigger than maximum ... "
set +e
$ATFTP --option "blksize 65465" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
set -e
if grep -q "<Failure to negotiate RFC2347 options>" "$OUTPUTFILE"; then
	echo OK
else
	echo ERROR
	ERROR=1
fi

#
# testing for tsize
#
OUTPUTFILE="03-out"
echo ""
echo -n "Testing tsize option... "
$ATFTP --option "tsize" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
TSIZE=$(grep "OACK <tsize:" "$OUTPUTFILE" | sed -e "s/[^0-9]//g")
if [ "$TSIZE" != "2048" ]; then
	echo "ERROR (server report $TSIZE bytes but it should be 2048)"
	ERROR=1
else
	echo "OK"
fi

#
# testing for timeout
#
OUTPUTFILE="04-out"
echo ""
echo "Testing timeout option limit..."
echo -n " minimum ... "
set +e
$ATFTP --option "timeout 0" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
set -e
if grep -q "<Failure to negotiate RFC2347 options>" "$OUTPUTFILE"; then
	echo OK
else
	echo ERROR
	ERROR=1
fi
echo -n " maximum ... "
set +e
$ATFTP --option "timeout 256" --trace --get -r $READ_2K -l /dev/null $HOST $PORT 2> "$OUTPUTFILE"
set -e
if grep -q "<Failure to negotiate RFC2347 options>" "$OUTPUTFILE"; then
	echo OK
else
	echo ERROR
	ERROR=1
fi

# Test the behaviour when the server is not reached
# we assume there is no tftp server listening on 127.0.0.77
# Returncode must be 255
OUTPUTFILE="05-out"
echo
echo -n "Test returncode after timeout when server is unreachable ... "
set +e
$ATFTP --put --local-file "$DIRECTORY/$READ_2K" 127.0.0.77 2>"$OUTPUTFILE"
Retval=$?
set -e
echo -n "Returncode $Retval: "
if [ $Retval -eq 255 ]; then
	echo "OK"
else
	echo "ERROR"
	ERROR=1
fi

# Test behaviour when disk is full
#
# Preparation: create a small ramdisk
# we need the "sudo" command for that
if [[ $WANT_INTERACTIVE_TESTS = "yes" ]]; then
	echo
	SMALL_FS_DIR="${DIRECTORY}/small_fs"
	echo "Start disk-out-of-space tests, prepare filesystem in ${SMALL_FS_DIR}  ..."
	mkdir "$SMALL_FS_DIR"
	if [[ $(id -u) -eq 0 ]]; then
		Sudo=""
	else
		Sudo="sudo"
		echo "trying to mount ramdisk, the sudo command may ask for a password on the next line!"
	fi
	$Sudo mount -t tmpfs shm "$SMALL_FS_DIR" -o size=500k
	echo "disk space before test: $(LANG=C df -k -P "${SMALL_FS_DIR}" | grep "${SMALL_FS_DIR}" | awk '{print $4}') kiB"
	echo
	echo -n "Put 1M file to server: "
	$ATFTP --put --local-file "$DIRECTORY/$READ_1M" --remote-file "small_fs/fillup.bin" $HOST $PORT
	Retval=$?
	sleep 1
	echo -n "Returncode $Retval: "
	if [ $Retval -ne 0 ]; then
		echo "OK"
	else
		echo "ERROR"
		ERROR=1
	fi
	rm "$DIRECTORY/small_fs/fillup.bin"
	echo
	echo -n "Get 1M file from server: "
	$ATFTP --get --remote-file "$READ_1M" --local-file "$DIRECTORY/small_fs/fillup-put.bin" $HOST $PORT
	Retval=$?
	sleep 1
	echo -n "Returncode $Retval: "
	if [ $Retval -ne 0 ]; then
		echo "OK"
	else
		echo "ERROR"
		ERROR=1
	fi
	$Sudo umount "$SMALL_FS_DIR"
	rmdir "$SMALL_FS_DIR"
else
	echo
	echo "Disk-out-of-space tests not performed, start with \"WANT_INTERACTIVE_TESTS=yes ./test.sh\" if desired."
fi

# Test that timeout is well set to 1 sec and works.
# we need atftp compiled with debug support to do that
# Restart the server with full logging
OUTPUTFILE="06-out"
if $ATFTP --help 2>&1 | grep --quiet -- --delay
then
	stop_server
	OLD_ARGS="$SERVER_ARGS"
	SERVER_ARGS="$SERVER_ARGS --verbose=7"
	start_server

	$ATFTP --option "timeout 1" --delay 200 --get -r $READ_2K -l /dev/null $HOST $PORT 2> /dev/null &
	CPID=$!
	sleep 1
	kill -s STOP $CPID
	echo -n "Testing timeout "
	for i in $(seq 6); do
		sleep 1
		echo -n "."
	done
	kill $CPID

	stop_server

	sleep 1
	grep "timeout: retrying..." $SERVER_LOG | cut -d " " -f 3 > "$OUTPUTFILE"
	count=$(wc -l "$OUTPUTFILE" | cut -d "o" -f1)
	if [ $count != 5 ]; then
		ERROR=1
		echo "ERROR"
	else
		prev=0
		res="OK"
		while read line; do
			hrs=$(echo $line | cut -d ":" -f 1)
			min=$(echo $line | cut -d ":" -f 2)
			sec=$(echo $line | cut -d ":" -f 3)
			cur=$(( 24*60*10#$hrs + 60*10#$min + 10#$sec ))

			if [ $prev -gt 0 ]; then
				if [ $(($cur - $prev)) != 1 ]; then
					res="ERROR"
					ERROR=1
				fi
			fi
			prev=$cur
		done < "$OUTPUTFILE"
		echo " $res"
	fi
	SERVER_ARGS="$OLD_ARGS"
	start_server
else
	echo
	echo "Detailed timeout test could not be done"
	echo "Compile atftp with debug support for more timeout testing"
fi

#
# testing PCRE
#
echo -en "\nTesting PCRE substitution ... "
if diff -u <($ATFTPD --pcre-test ./pcre_pattern.txt <<EOF
nomatch
ppxelinux.cfg/012345
ppxelinux.cfg/678
ppxelinux.cfg/9ABCDE
pppxelinux.0
pxelinux.cfg/F
linux
something_linux_like
str
strong
validstr
doreplacethis
any.conf
EOF
            ) <(cat <<EOF
Substitution: "nomatch" -> ""
Substitution: "ppxelinux.cfg/012345" -> "pxelinux.cfg/default"
Substitution: "ppxelinux.cfg/678" -> "pxelinux.cfg/default"
Substitution: "ppxelinux.cfg/9ABCDE" -> "pxelinux.cfg/default"
Substitution: "pppxelinux.0" -> "pppxelinux.0"
Substitution: "pxelinux.cfg/F" -> "pxelinux.cfg/default"
Substitution: "linux" -> "linux"
Substitution: "something_linux_like" -> "something_linux_like"
Substitution: "str" -> "replaced1"
Substitution: "strong" -> "replaced2ong"
Substitution: "validstr" -> "validreplaced3"
Substitution: "doreplacethis" -> "domacethis"
Substitution: "any.conf" -> "master.conf"
EOF
               ) ; then
    echo OK
else
    ERROR=1
    echo "ERROR"
fi

#
# testing multicast
#

#echo ""
#echo -n "Testing multicast option  "
#for i in $(seq 10); do
#	echo -n "."
#	atftp --blksize=8 --multicast -d --get -r $READ_BIG -l out.$i.bin $HOST $PORT 2> /dev/null&
#done
#echo "OK"

#
# testing mtftp
#


#
# Test for high server load
#
echo
echo "Testing high server load"
echo -n "  starting $NBSERVER simultaneous atftp get processes "
#( for i in $(seq 1 $NBSERVER); do
#	($ATFTP --get --remote-file $READ_1M --local-file /dev/null $HOST $PORT 2> out.$i) &
#	echo -n "+"
#done )
set +e
for i in $(seq 1 $NBSERVER) ; do
    echo -n "."
    $ATFTP --get --remote-file $READ_1M --local-file /dev/null $HOST $PORT 2> "$DIRECTORY/high-server-load-out.$i" &
done
set -e
echo " done"
CHECKCOUNTER=0
MAXCHECKS=90
while [[ $CHECKCOUNTER -lt $MAXCHECKS ]]; do
	PIDCOUNT=$(pidof $ATFTP|wc -w)
	if [ $PIDCOUNT -gt 0 ]; then
		echo "  wait for atftp processes to complete: $PIDCOUNT running"
		CHECKCOUNTER=$((CHECKCOUNTER + 1))
		sleep 1
	else
		CHECKCOUNTER=$((MAXCHECKS + 1))
	fi
done
#
# high server load test passed, now examine the results
#
>"$DIRECTORY/high-server-load-out.result"
for i in $(seq 1 $NBSERVER); do
	# merge all output together
	cat "$DIRECTORY/high-server-load-out.$i" >>"$DIRECTORY/high-server-load-out.result"
done

# remove timeout/retry messages, they are no error indicator
grep -v "timeout: retrying..." "$DIRECTORY/high-server-load-out.result" \
     > "$DIRECTORY/high-server-load-out.clean-result" || true

# the remaining output is considered as error messages
error_cnt=$(wc -l <"$DIRECTORY/high-server-load-out.clean-result")

# print out error summary
if [ "$error_cnt" -gt "0" ]; then
	echo "Errors occurred during high server load test, # lines output: $error_cnt"
	echo "======================================================"
	cat "$DIRECTORY/high-server-load-out.clean-result"
	echo "======================================================"
	ERROR=1
else
	echo -e "High server load test: OK\n"
fi

# remove all empty output files
find "$DIRECTORY" -name "high-server-load-out.*" -size 0 -delete

stop_server
trap - EXIT SIGINT SIGTERM
tail -n 14 "$SERVER_LOG" | cut -d ' ' -f6-
echo
## + 1 is for "Testing tsize option... "
cat <<EOF
Expected:
   number of errors:         $(grep -c '<Failure\s\|<File not\s' $0)
   number of files sent:     $(( $(grep -c "^test_get_put" $0) + $NBSERVER + 1 ))
   number of files received: $(grep -c "^test_get_put" $0)

EOF


# cleanup
if [ $CLEANUP -ne 1 ]; then
	echo "No cleanup, files from test are left in $DIRECTORY"
else
	echo "Cleaning up test files"
	rm -f ??-out $SERVER_LOG
	cd "$DIRECTORY"
	rm -f $READ_0 $READ_511 $READ_512 $READ_2K $READ_BIG $READ_128K \
           $READ_1M $READ_10M $READ_101M $WRITE high-server-load-out.*
	cd ..
	rmdir "$DIRECTORY"
fi

echo -n "Overall Test status: "
# Exit with proper error status
if [ $ERROR -eq 1 ]; then
	echo "Errors have occurred"
	exit 1
else
	echo "OK"
fi

# vim: ts=4:sw=4:autoindent
