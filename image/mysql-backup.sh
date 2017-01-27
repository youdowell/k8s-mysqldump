#!/bin/bash
#
# MySQL dump script.
#
set -e

: ${DB_HOST}
: ${DB_USER}
: ${DB_PASS}
: ${BACKUP_DIR}

DB_SKIP=${DB_SKIP:-"information_schema,performance_schema,mysql"}

log_name=$(basename $0)
start_time=$SECONDS
tstamp_fmt="%Y%m%d_%H%M"
tstamp=$(date -u +"$tstamp_fmt")
mysqldump=(mysqldump --user="${DB_USER}" --password="${DB_PASS}" --host="${DB_HOST}" --single-transaction --routines --triggers --complete-insert --hex-blob "$@")
mysql=(mysql --user="${DB_USER}" --password="${DB_PASS}" --host="${DB_HOST}")

log() {
	echo "[INFO] $log_name - $@"
}

# --------------------------------------
# MySQL Backup
# --------------------------------------
mkdir -p $BACKUP_DIR
rm -rf $BACKUP_DIR/*

# Perform backup
if [ -z "$DB_NAME" ]; then
	log "Starting full backup..."
	dump="${BACKUP_DIR}/all-databases.sql.gz"
	# --add-drop-database
	"${mysqldump[@]}" --all-databases | gzip > "$dump"

else
	log "Starting backup..."
	if [ "$DB_NAME" == "*" ]; then
		databases=($("${mysql[@]}" -e "SHOW DATABASES;" | tr -d "| " | grep -v Database))
	else
		databases=(${DB_NAME//,/ })
	fi

	if [ -n "$DB_SKIP" ]; then
    	filtered_databases=" ${databases[*]} "
        for dbname in ${DB_SKIP//,/ }; do
    		log "Skipping '$dbname'"
    		filtered_databases=${filtered_databases/ ${dbname} / }
        done
        databases=($filtered_databases)
	fi

	for dbname in ${databases[@]}; do
    	log "Creating dump for '${dbname}'..."
    	dump="${BACKUP_DIR}/${dbname}.sql.gz"
    	"${mysqldump[@]}" "${dbname}" | gzip > "$dump"
	done
fi

total_size=$(du -sh "$BACKUP_DIR" | cut -f1)
elapsed_time=$(($SECONDS - $start_time))
log "Done within $elapsed_time seconds. Total size: $total_size."

# --------------------------------------
# AWS S3 Upload (optional)
# --------------------------------------
if [ -n "$S3_BACKUP_URI" ]; then
	latest_uri="$S3_BACKUP_URI/latest"
	history_uri="$S3_BACKUP_URI/history/$tstamp"
    bucket_name=$(echo $S3_BACKUP_URI | cut -d'/' -f3)
    aws_cli=(aws)

	# Use custom S3 endpoint if specified
	[ -n "$S3_ENDPOINT" ] && aws_cli+=("--endpoint-url=$S3_ENDPOINT")

    # Create S3 bucket if necessary
    if ! "${aws_cli[@]}" s3api head-bucket --bucket "$bucket_name"; then
        log "Creating new S3 bucket..."
        "${aws_cli[@]}" s3api create-bucket --bucket "$bucket_name"
    fi

    log "Uploading backup files to '$history_uri'..."
    "${aws_cli[@]}" s3 sync "$BACKUP_DIR" "$history_uri" --delete --quiet
    log "Updating '$latest_uri'..."
    "${aws_cli[@]}" s3 sync "$history_uri" "$latest_uri" --delete --quiet

    elapsed_time=$(($SECONDS - $start_time))
    log "Uploaded within $elapsed_time seconds. Timestamp: $tstamp."
fi
