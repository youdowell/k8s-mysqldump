# Docker container with MySQL dump and AWS CLI

Docker image to perform mysql backup to AWS S3 using mysqldump and mysql CLI in Kubernetes.

## Settings

Configuration variables:

* `DB_USER` - The mysql root user name
* `DB_PASS` - The mysql root password
* `DB_HOST` - The mysql host name
* `DB_NAME` - If not empty, the comma-seaprated list of database names to include into the backup or "*" for all databases in individual files, otherwise backup all databases in a single backup.
* `S3_BACKUP_URI` - (optional) The AWS S3 bucket URI where backups are stored, e.g. `s3://my-bucket/backups/mysql`.
* `S3_ENDPOINT` - (optional) Use custom endpoint for AWS CLI, useful for testing.

## Storing backups on AWS S3

If the backup S3 URI is specified, the dump files are uploaded to the following locations:

*  `$S3_BACKUP_URI/latest` - The latest backup dir
*  `$S3_BACKUP_URI/history/$tstamp` - The history backup dir, for example `s3://my-bucket/backups/mysql/history/20170120_235959`
