#!/bin/bash
#
# Argument = -i host -k key -s secret -b bucket -r region
#
# To Do - Add logging of output.

set -e

usage()
{
cat << EOF
usage: $0 options

This script dumps the current mongo database, tars it, then sends it to an Amazon S3 bucket.

OPTIONS:
   -h      Show this message
   -i      Mongo host
   -k      AWS Access Key
   -s      AWS Secret Key
   -r      Amazon S3 region
   -b      Amazon S3 bucket name
EOF
}

AWS_ACCESS_KEY=
AWS_SECRET_KEY=
S3_REGION=
S3_BUCKET=
MONGODB_HOST=

while getopts "ht:k:s:r:b:i:" OPTION
do
  case $OPTION in
    h)
      usage
      exit 1
      ;;
    k)
      AWS_ACCESS_KEY=$OPTARG
      ;;
    s)
      AWS_SECRET_KEY=$OPTARG
      ;;
    r)
      S3_REGION=$OPTARG
      ;;
    b)
      S3_BUCKET=$OPTARG
      ;;
    i)
      MONGODB_HOST=$OPTARG
      ;;
    ?)
      usage
      exit
    ;;
  esac
done

if [[ -z $MONGODB_HOST ]] || [[ -z $AWS_ACCESS_KEY ]] || [[ -z $AWS_SECRET_KEY ]] || [[ -z $S3_REGION ]] || [[ -z $S3_BUCKET ]]
then
  usage
  exit 1
fi

# Get the directory the script is being run from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo $DIR

# Store the current date in YYYY-mm-DD-HHMMSS
DATE=$(date -u "+%F-%H%M%S")
FILE_NAME="backup-$DATE"
ARCHIVE_NAME="$FILE_NAME.tar.gz"

# Get if server is part of replica, if yes get slave address
MONGODB_INSTANCE=$(mongo --host $MONGODB_HOST admin --quiet --eval "var repl = rs.status(); if (repl.ok) { for (var i in repl.members) { if (repl.members[i].stateStr == 'SECONDARY') { printjson(repl.members[i].name); break; }}}" | sed s/\"//g)

# If not replica, use localhost
if [[ -z $MONGODB_INSTANCE ]]
then
  MONGODB_INSTANCE="localhost:27017"
fi

# Lock the database
# Note there is a bug in mongo 2.2.0 where you must touch all the databases before you run mongodump
mongo --host $MONGODB_INSTANCE admin --eval "var databaseNames = db.getMongo().getDBNames(); rs.slaveOk(); for (var i in databaseNames) { printjson(db.getSiblingDB(databaseNames[i]).getCollectionNames()) }; printjson(db.fsyncLock());"

# Dump the database
mongodump --host $MONGODB_INSTANCE --out $DIR/backup/$FILE_NAME

# Unlock the database
mongo --host $MONGODB_INSTANCE admin --eval "printjson(db.fsyncUnlock());"

# Tar Gzip the file
tar -C $DIR/backup/ -zcvf $DIR/backup/$ARCHIVE_NAME $FILE_NAME/

# Remove the backup directory
rm -r $DIR/backup/$FILE_NAME

# Send the file to the backup drive or S3

HEADER_DATE=$(date -u "+%a, %d %b %Y %T %z")
CONTENT_MD5=$(openssl dgst -md5 -binary $DIR/backup/$ARCHIVE_NAME | openssl enc -base64)
CONTENT_TYPE="application/x-download"
STRING_TO_SIGN="PUT\n$CONTENT_MD5\n$CONTENT_TYPE\n$HEADER_DATE\n/$S3_BUCKET/$ARCHIVE_NAME"
SIGNATURE=$(echo -e -n $STRING_TO_SIGN | openssl dgst -sha1 -binary -hmac $AWS_SECRET_KEY | openssl enc -base64)

curl -X PUT \
--header "Host: $S3_BUCKET.s3-$S3_REGION.amazonaws.com" \
--header "Date: $HEADER_DATE" \
--header "content-type: $CONTENT_TYPE" \
--header "Content-MD5: $CONTENT_MD5" \
--header "Authorization: AWS $AWS_ACCESS_KEY:$SIGNATURE" \
--upload-file $DIR/backup/$ARCHIVE_NAME \
https://$S3_BUCKET.s3-$S3_REGION.amazonaws.com/$ARCHIVE_NAME
