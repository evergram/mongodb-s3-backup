#!/bin/bash
#
# Argument = -h host -k key -s secret -b bucket -r region
#
# To Do - Add logging of output.

set -e

usage()
{
cat << EOF
usage: $0 options

This script dumps the current mongo database, tars it, then sends it to an Amazon S3 bucket.

OPTIONS:
   -u      Show this message
   -h      Mongo host
   -k      AWS Access Key
   -s      AWS Secret Key
   -r      Amazon S3 region
   -b      Amazon S3 bucket name
   -d      Amazon S3 directory (optional)
EOF
}

AWS_ACCESS_KEY=
AWS_SECRET_KEY=
S3_REGION=
S3_BUCKET=
S3_DIRECTORY=
MONGODB_HOST=

while getopts "ud:h:k:s:r:b:" OPTION
do
  case $OPTION in
    u)
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
    d)
      S3_DIRECTORY=$OPTARG
      ;;
    h)
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

# Store the current date in YYYY-mm-DD-HHMM
DATE=$(date -u "+%F-%H%M")
FILE_NAME="backup-$DATE"
ARCHIVE_NAME="$FILE_NAME.tar.gz"

if [[ -z $S3_DIRECTORY ]]; then
    S3_DIRECTORY="/"
else
    S3_DIRECTORY="/${S3_DIRECTORY}/"
fi

S3_LOCATION="https://${S3_BUCKET}.s3-${S3_REGION}.amazonaws.com${S3_DIRECTORY}${ARCHIVE_NAME}"

echo -e "Backing up from ${MONGODB_HOST} to a local file ${ARCHIVE_NAME}.\n"

echo -e "Checking mongo for replica set\n"
# Get if server is part of replica, if yes get slave address
MONGODB_INSTANCE=$(mongo --host $MONGODB_HOST admin --quiet --eval "var repl = rs.status(); if (repl.ok) { for (var i in repl.members) { if (repl.members[i].stateStr == 'SECONDARY') { printjson(repl.members[i].name); break; }}}" | sed s/\"//g)

# If no replica, use localhost
if [[ -z $MONGODB_INSTANCE ]]; then
    echo -e "No secondary instance found. Using localhost.\n"
    MONGODB_INSTANCE="localhost:27017"
elif [[ $MONGODB_INSTANCE =~ .*Error.* ]]; then
    echo -e "Error connecting to mongo:\n\n ${MONGODB_INSTANCE}\n"
    exit 1
else
    echo -e "Found secondary instance: ${MONGODB_INSTANCE}.\n"
fi

echo -e "Running mongodump...\n"

# Dump the database
mongodump --host $MONGODB_INSTANCE --out $DIR/backup/$FILE_NAME


echo -e "Completed mongodump to ${DIR}/backup/${FILE_NAME}\n"
echo -e "Compressing the backup\n"

# Tar Gzip the file
tar -C $DIR/backup/ -zcvf $DIR/backup/$ARCHIVE_NAME $FILE_NAME/

# Remove the backup directory
rm -r $DIR/backup/$FILE_NAME

# Send the file to the backup drive or S3

HEADER_DATE=$(date -u "+%a, %d %b %Y %T %z")
CONTENT_MD5=$(openssl dgst -md5 -binary ${DIR}/backup/${ARCHIVE_NAME} | openssl enc -base64)
CONTENT_TYPE="application/x-download"
STRING_TO_SIGN="PUT\n${CONTENT_MD5}\n${CONTENT_TYPE}\n${HEADER_DATE}\n/${S3_BUCKET}${S3_DIRECTORY}${ARCHIVE_NAME}"
SIGNATURE=$(echo -e -n ${STRING_TO_SIGN} | openssl dgst -sha1 -binary -hmac ${AWS_SECRET_KEY} | openssl enc -base64)

echo -e "Uploading the backup to ${S3_LOCATION}\n"

curl -X PUT \
--header "Host: ${S3_BUCKET}.s3-${S3_REGION}.amazonaws.com" \
--header "Date: ${HEADER_DATE}" \
--header "content-type: ${CONTENT_TYPE}" \
--header "Content-MD5: ${CONTENT_MD5}" \
--header "Authorization: AWS ${AWS_ACCESS_KEY}:${SIGNATURE}" \
--upload-file ${DIR}/backup/${ARCHIVE_NAME} \
${S3_LOCATION}

rm -r $DIR/backup/$ARCHIVE_NAME

echo -e "Successfully completed the backup to ${S3_LOCATION}\n"
