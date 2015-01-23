#!/bin/bash

FLAG_INTERACTIVE="1"
OPT=1
while [ "$OPT" = "1" ]; do
    O="$1"
    if   [ "$O" = "-i" ]; then FLAG_INTERACTIVE="1"; shift;
    elif [ "$O" = "-f" ]; then FLAG_INTERACTIVE="0"; shift;
    else OPT="0" ## break option loop
    fi
done

SSH_SOURCE="$1"
DEV_SOURCE="$2"
SSH_TARGET="$3"
DEV_TARGET="$4"

SIZE_BLOCK="$5"
if [ "$SIZE_BLOCK" = "" ]; then SIZE_BLOCK=1048576; fi

if [ "$SSH_SOURCE" = "" -o "$DEV_SOURCE" = "" -o "$SSH_TARGET" = "" -o "$DEV_TARGET" = "" ]; then
    echo "Usage: $0 [options] -|<user@source_host> <source_device> -|<user@target_host> <target_device> [block_size]"
    echo
    echo "Sync block devices. Allows local-local, local-remote, remote-local and remote-remote modes of operation."
    echo "Remote access uses SSH. Local mode is selected using - (dash) instead of <user@host> SSH connection parameters."
    echo "Default blocksize is 1MB."
    echo
    echo "Options"
    echo "      -i  Interactive mode (default)"
    echo "      -f  Force operation, skip interactive mode"
    echo
    exit 1
fi

## ssh / local commands
SSH_OPTS="-C -c arcfour"
if [ "$SSH_SOURCE" = "-" ]; then
    XS="bash -c"
else
    XS="ssh $SSH_OPTS $SSH_SOURCE"
fi
if [ "$SSH_TARGET" = "-" ]; then
    XT="bash -c"
else
    XT="ssh $SSH_OPTS $SSH_TARGET"
fi


function isNumber {
    local num="$1"
    [ ! -z "${num##*[!0-9]*}" ] && return 0 || return 1
}

## device size
SIZE_SOURCE=`$XS "blockdev --getsize64 $DEV_SOURCE"`
isNumber "$SIZE_SOURCE" || { echo "Can't get source device size"; exit 1; }
SIZE_TARGET=`$XT "blockdev --getsize64 $DEV_TARGET"`
isNumber "$SIZE_TARGET" || { echo "Can't get target device size"; exit 1; }

if [ "$SIZE_SOURCE" = "$SIZE_TARGET" ]; then
    echo "Device size: $SIZE_SOURCE"
else
    echo "ERROR - source and target device size differs: $SIZE_SOURCE -> $SIZE_TARGET"
    exit 1
fi

## hash size + progress
SIZE_HASH=16
SIZE_PROGRESS=$(($SIZE_SOURCE / $SIZE_BLOCK))
SIZE_CHECK=$(($SIZE_PROGRESS * $SIZE_BLOCK))
if [ "$SIZE_SOURCE" != "$SIZE_CHECK" ]; then
    echo "Invalid block size: $SIZE_BLOCK";
    exit 1;
fi

## commands
C1_SUM="perl -'MDigest::MD5 md5' -ne 'BEGIN{\$/=\\$SIZE_BLOCK; STDOUT->autoflush(1);}; print md5(\$_)' '$DEV_TARGET'"
C2_SEND="perl -'MDigest::MD5 md5' -ne 'BEGIN{\$/=\\$SIZE_BLOCK; STDOUT->autoflush(1);}; \$b=md5(\$_); read STDIN,\$a,$SIZE_HASH; if (\$a eq \$b) {print \"s\";} else {print \"c\".\$_;}' $DEV_SOURCE"
C3_WRITE=""
C3_WRITE="$C3_WRITE perl -MFcntl -ne '"
C3_WRITE="$C3_WRITE BEGIN{\$/=\\1;"
	C3_WRITE="$C3_WRITE STDOUT->autoflush(1);"
	C3_WRITE="$C3_WRITE open (F, \"+<\", \"$DEV_TARGET\"); F->autoflush(1); \$flags = fcntl(F, F_GETFL, 0); \$flags|=O_DSYNC; fcntl(F, F_SETFL, \$flags);"
C3_WRITE="$C3_WRITE };"
C3_WRITE="$C3_WRITE END{close(F); print STDERR sprintf(\"\\nwritten total %d bytes, %.6f %%\\n\",\$w,(\$w/$SIZE_SOURCE*100)); };"
C3_WRITE="$C3_WRITE print \".\"; if (\$_ eq \"s\") {\$s++;} else {if (\$s) {"
	C3_WRITE="$C3_WRITE seek F,\$s*$SIZE_BLOCK,1; \$s=0;};"
	C3_WRITE="$C3_WRITE \$len = read STDIN,\$buf,$SIZE_BLOCK; die \"Invalid LEN\" if (\$len ne \"$SIZE_BLOCK\");"
	C3_WRITE="$C3_WRITE print F \$buf; \$w+=$SIZE_BLOCK;"
	C3_WRITE="$C3_WRITE if (60+\$lw<time()) {\$lw=time(); print STDERR sprintf(\"\\nwritten %d bytes, %.6f %%\\n\",\$w,(\$w/$SIZE_SOURCE*100)); };"
C3_WRITE="$C3_WRITE };"
C3_WRITE="$C3_WRITE '"

if [ "$FLAG_INTERACTIVE" = "1" ]; then
    echo "C1 SUM:   $XT \"$C1_SUM\""
    echo "C2 SEND:  $XS \"$C2_SEND\""
    echo "C3 WRITE: $XT \"$C3_WRITE\""
    echo
    echo "Press ENTER to continue ..."
    read
fi

$XT "$C1_SUM" \
    | $XS "$C2_SEND" \
    | $XT "$C3_WRITE" | pv -W -B 1 -s "$SIZE_PROGRESS" >/dev/null

echo
echo
echo Finished
echo
