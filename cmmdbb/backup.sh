#!/bin/bash
echo "CM MongoDB Backup (cmmdbb) v.0.2.3, 2019-02-21"
if [ -z "$APP_NAME" ]
then
  echo "APP_NAME must be set, exiting!"
  exit 1
fi

# echo "ENV:"
# printenv

echo "Waiting 3s..."
sleep 3 # helpful for local testing

# To inject more options, like '--db test', /u, /p, /oplog, etc.
MONGODUMP_OPTIONS=${MONGODUMP_OPTIONS:-""}

echo "Backup started for $MONGO_HOST, db $MONGO_DATABASE"
TIMESTAMP=`date +%F-%H%M`
MONGODUMP_PATH="/usr/bin/mongodump"
GPG_PATH="gpg"
GPG_FILE="/etc/gpg-pk/gpg.pub" # needs to match k8s secret mount point
BACKUPS_DIR="/backups/$APP_NAME"
BACKUP_NAME="$APP_NAME-$TIMESTAMP"
ARCHIVE_PATH="$BACKUPS_DIR/$BACKUP_NAME.gz"
if [ -e $BACKUPS_DIR ]
then
  echo "backup directory $BACKUPS_DIR already exists"
else
  mkdir $BACKUPS_DIR
fi
echo "executing $MONGODUMP_PATH --host $MONGO_HOST $MONGODUMP_OPTIONS --archive=$ARCHIVE_PATH --gzip"
$MONGODUMP_PATH --host $MONGO_HOST $MONGODUMP_OPTIONS --archive=$ARCHIVE_PATH --gzip

if [ -e $ARCHIVE_PATH ]
then
  echo "MongoDB dump created successfully"
else
  echo "Failed to create MongoDB dump, aborting!"
  exit 2
fi

if [ -e $GPG_FILE ]
then
  # need to temp-import the key. Key is given as file /etc/gpg-pk/gpg.pub which is mounted from a k8s secret
  # https://security.stackexchange.com/questions/86721/can-i-specify-a-public-key-file-instead-of-recipient-when-encrypting-with-gpg
  echo "importing GPG key..."
  echo "executing GPG: $GPG_PATH --no-default-keyring --primary-keyring ./temp.gpg --import $GPG_FILE"
  $GPG_PATH --no-default-keyring --primary-keyring ./temp.gpg --import $GPG_FILE
  # I don't feel like relying on implementation detail AT ALL here... (head, tail, cut...)
  echo "executing GPG: $GPG_PATH --list-public-keys --batch --with-colons --no-default-keyring --primary-keyring ./temp.gpg | head -n2 | tail -n1 | cut -d: -f5"
  KEYID=`$GPG_PATH --list-public-keys --batch --with-colons --no-default-keyring --primary-keyring ./temp.gpg | head -n2 | tail -n1 | cut -d: -f5`
  echo "executing GPG: $GPG_PATH --no-default-keyring --primary-keyring ./temp.gpg --batch --yes --trust-model always -r $KEYID -e $ARCHIVE_PATH"
  $GPG_PATH --no-default-keyring --primary-keyring ./temp.gpg --batch --yes --trust-model always -r $KEYID -e $ARCHIVE_PATH
  ARCHIVE_PATH="$ARCHIVE_PATH.gpg"
else
  echo "GPG pub key file at $GPG_FILE not found, proceeding w/o encryption"
fi

if [ -z "$S3_BUCKET_NAME" ]
then
  echo "S3_BUCKET_NAME is empty, not uploading to S3..."
else
  echo "uploading backup to S3..."
  echo "executing s3cmd put --acl-private --guess-mime-type $ARCHIVE_PATH s3://$S3_BUCKET_NAME$ARCHIVE_PATH"
  s3cmd put --access_key=$S3_ACCESS_KEY --secret_key=$S3_SECRET_KEY --acl-private --guess-mime-type $ARCHIVE_PATH s3://$S3_BUCKET_NAME$ARCHIVE_PATH
fi

echo "cleaning up..."
rm -r $BACKUPS_DIR
echo "DONE."
