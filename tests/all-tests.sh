#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"

NAMESPACE="mysqldump-test"
label="app=mysqldump"
s3_uri="s3://my-bucket/backup/mysql"

FAILED="`tput setaf 1`FAILED`tput sgr0`"
PASSED="`tput setaf 2`PASSED`tput sgr0`"
TIMEOUT=120s

# --------------------------------------
# K8S RESOURCES
# --------------------------------------
create() {
	kubectl create namespace ${NAMESPACE} --dry-run -o yaml | kubectl apply -f -
	kubectl --namespace ${NAMESPACE} apply --recursive --timeout=$TIMEOUT -f "$DIR/example"
}

start() {
	kubectl --namespace ${NAMESPACE} apply -l "$label" --recursive --timeout=$TIMEOUT -f "$DIR/example"
}

stop() {
	kubectl --namespace ${NAMESPACE} delete deployment -l "$label"

	echo -n "Waiting until all pods are stopped ["
	timeout=$((SECONDS + 120))
	while [ $SECONDS -lt $timeout ]; do
		pods=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --no-headers 2>/dev/null)
		[ -z "$pods" ] && echo "OK]" && break
		sleep 2
		echo -n "."
	done
}

clean() {
	kubectl --namespace ${NAMESPACE} delete --all -f "$DIR/example"
	kubectl delete namespace ${NAMESPACE} --timeout=$TIMEOUT --force
}

# --------------------------------------
# UTILITIES
# --------------------------------------

before() {
	echo
	echo "[+] $1"
	RUNNING_TEST=$1
	ERRORS=()
	start
	wait_mysql_ready 1
}

after() {
	echo ----------------------------------------
}

pass() {
	echo "[+] ${FUNCNAME[1]}: $PASSED"
}

fail() {
	#stacktrace=(${FUNCNAME[@]:1})
	#unset 'stacktrace[${#stacktrace[@]}-1]'
	msg="$@"
	echo "[+] ${FUNCNAME[1]}: $FAILED ${msg:+"- $msg"}"
	echo
	ERRORS+=("${FUNCNAME[1]} ${msg}")
	exit 1
}

exec_sql() {
	pod=$1
	sql=$2
	mysql_cmd='mysql -u"${MYSQL_ROOT_USER}" -p"${MYSQL_ROOT_PASSWORD}"'
	kubectl --namespace ${NAMESPACE} exec "$pod" -- bash -c "${mysql_cmd} -e '${sql}' -q --skip-column-names ${@:3}"
}

exec_mysqldump() {
	pod=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --template='{{(index .items 0).metadata.name}}')
	set -x
	kubectl --namespace ${NAMESPACE} exec "$pod" "${@}"
	set +x
}

logs_mysqldump() {
	pod=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --template='{{(index .items 0).metadata.name}}')
	set -x
kubectl --namespace ${NAMESPACE} logs "$pod" "${@}"
	set +x
}

populate_test_data() {
	pod=${1:-"mysql-0"}
	degree=${2:-20}
	exec_sql "$pod" 'DROP DATABASE IF EXISTS test;'
	exec_sql "$pod" 'CREATE DATABASE test;'
	exec_sql "$pod" 'CREATE TABLE test.rnd_values (id BIGINT NOT NULL AUTO_INCREMENT, val INT NOT NULL, PRIMARY KEY (id));'
	exec_sql "$pod" 'INSERT INTO test.rnd_values (val) VALUES (rand()*10000);'
	echo -n "Populating random values ["
   	for i in $(seq 1 $degree); do
		exec_sql "$pod" 'INSERT INTO test.rnd_values (val) SELECT a.val * rand() FROM test.rnd_values a;'
		cnt=$(exec_sql "$pod" "SELECT count(*) from test.rnd_values;")
		echo -n "...$cnt"
   	done
	echo "]"
}

TIME_SEC=1
TIME_MIN=$((60 * $TIME_SEC))

time_now() {
  echo $(date +%s)
}

wait_command() {
	: ${1:?"wait_command: Command required!"}
	cmd=$1
	max_wait=${2:-30*TIME_SEC}

	STARTTIME=$(date +%s)
	expire=$(($STARTTIME + $max_wait))
	wait=0.5

	echo -n "[INFO] Waiting for command to finish ["
	set +e
	while [ $(date +%s) -lt $expire ]; do
		if eval "$cmd"; then
	set -e
			ENDTIME=$(date +%s)
			echo "OK after $(($ENDTIME - $STARTTIME)) seconds]"
			return 0
		fi
		echo -n "."
		sleep $wait
	done
	set -e
	echo "Gave up waiting for command to finish!]"
	fail
	return 1
}

mysql_pod_count() {
	kubectl --namespace ${NAMESPACE} get pods -l "app=mysql" -o yaml 2>/dev/null | grep "ready: true" -c || true
}

wait_mysql_ready() {
	wait_count=${1:-1}
	echo "[INFO] Waiting until exactly $wait_count mysql containers ready..."
	wait_command '[ $(mysql_pod_count) -ge ${wait_count} ]' ${2:-120}
	echo "[INFO] Mysql ready"
}


# --------------------------------------
# TESTS
# --------------------------------------
test_backup_created() {
	## Given
	populate_test_data "mysql-0" 4

 	## When
	mysqldump_pod=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --template='{{(index .items 0).metadata.name}}')
	kubectl --namespace ${NAMESPACE} exec $mysqldump_pod -- mysql-backup.sh

  	## Then
	echo "[INFO] Checking mysqldump pod '$mysqldump_pod' for dump files..."
	dump_files=($(kubectl --namespace ${NAMESPACE} exec $mysqldump_pod -- ls /data/mysqldump))

	echo "[INFO] Found dump files: $dump_files"
	[ -z "$dump_files" ] && fail "Dump files not found on pod '$mysqldump_pod'!"

	pass
}

test_backupS3_uploaded() {
	## Given
	populate_test_data "mysql-0" 4
	kubectl --namespace ${NAMESPACE} exec $mysqldump_pod -- aws --endpoint-url=http://fakes3 s3 rm --recursive "$s3_uri" && echo "S3 bucket cleared"

 	## When
	mysqldump_pod=$(kubectl --namespace ${NAMESPACE} get po -l "$label" --template='{{(index .items 0).metadata.name}}')
	kubectl --namespace ${NAMESPACE} exec $mysqldump_pod -- mysql-backup.sh

  	## Then
	echo "[INFO] Checking S3 bucket for latest dump files..."
	s3_dump_files=($(kubectl --namespace ${NAMESPACE} exec $mysqldump_pod -- aws --endpoint-url=http://fakes3 s3 ls "$s3_uri/latest/" | awk '{print $4}'))
	echo "[INFO] Found latest dump files on S3: $s3_dump_files"
	[ -z "$s3_dump_files" ] && fail "Latest dump files not found on S3!"

	pass
}

# --------------------------------------
# MAIN
# --------------------------------------
all_tests=$(sed -nE 's/^(test_[a-zA-Z0-9_]+)[[:space:]]*[\(\{].*$/\1/p' $0)

run_tests() {
	create
	echo "Running tests..."
	for testname in "$@"; do
		if ! [ ${testname:0:5} = "test_" ]; then
			echo "Invalid test name: $testname"
			exit 1
		fi
		before $testname
		eval $testname
		after $testname
	done
	clean
	echo "Done."
}

case "$1" in
	create)
		create
		;;
	start)
		start
		;;
	stop)
		stop
		;;
	clean)
		clean
		;;
	exec_sql)
		exec_sql "${@:2}"
		;;
	exec)
		exec_mysqldump "${@:2}"
		;;
	log)
		logs_mysqldump "${@:2}"
		;;
	test_*)
		run_tests ${@}
		;;
	"")
		run_tests ${all_tests}
		;;
	*)
		echo "Usage: $0 <tests...>"
		echo
		echo "Tests:"
		printf '\t%s\n' ${all_tests}
		;;
esac

exit 0
