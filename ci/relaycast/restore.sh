#!/usr/bin/env bash
# Restore a Relaycast release from a backup written by the chart's backup
# CronJob. Needs only kubectl and bash. Usage:
#   NS=relaycast RELEASE=relaycast BACKUP=relaycast-<UTC timestamp> ci/relaycast/restore.sh
# The engine is stopped for the copy and scheduled backups are suspended. The
# replaced database and files are moved to /data/pre-restore-<ts>/ on the data
# volume, never deleted.
set -euo pipefail
: "${NS:?set NS}" "${RELEASE:?set RELEASE}" "${BACKUP:?set BACKUP (a relaycast-<timestamp> directory)}"
[[ "$BACKUP" =~ ^relaycast-[0-9]{8}T[0-9]{6}Z(-[0-9a-f]{6})?$ ]] || { echo "BACKUP must look like relaycast-20260101T000000Z" >&2; exit 2; }
K="kubectl -n $NS"

# Find the release's Deployment by its instance label and the volumes that
# carry data and backups (works with nameOverride/fullnameOverride).
DEPLOY=
for d in $($K get deploy -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{.items[*].metadata.name}'); do
  if [ -n "$($K get deploy "$d" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="backup")].persistentVolumeClaim.claimName}')" ]; then DEPLOY=$d; fi
done
[ -n "$DEPLOY" ] || { echo "no Deployment for release $RELEASE with a backup volume (backup.enabled=false?)" >&2; exit 2; }
jp() { $K get deploy "$DEPLOY" -o jsonpath="$1"; }
IMAGE=$(jp '{.spec.template.spec.containers[0].image}')
DATA_CLAIM=$(jp '{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
BACKUP_CLAIM=$(jp '{.spec.template.spec.volumes[?(@.name=="backup")].persistentVolumeClaim.claimName}')
SEL=$($K get deploy "$DEPLOY" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}'); SEL=${SEL%,}
# Scheduling and pull settings come from the Deployment (JSON is valid YAML).
json() { local v; v=$(jp "$1"); printf '%s' "${v:-$2}"; }
PULL=$(json '{.spec.template.spec.imagePullSecrets}' '[]')
TOL=$(json '{.spec.template.spec.tolerations}' '[]')
NODESEL=$(json '{.spec.template.spec.nodeSelector}' '{}')
AFF=$(json '{.spec.template.spec.affinity}' '{}')
SEC=$(json '{.spec.template.spec.securityContext}' '{}')
CRON=$($K get cronjob -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backup" -o jsonpath='{.items[0].metadata.name}')
JOB="$DEPLOY-restore"

resume() { [ -n "$CRON" ] && $K patch cronjob "$CRON" -p '{"spec":{"suspend":false}}' >/dev/null || true; }
trap resume EXIT
# No backup may run while the data is replaced: suspend the schedule and wait
# for any running backup (scheduled or manual) to finish.
[ -n "$CRON" ] && $K patch cronjob "$CRON" -p '{"spec":{"suspend":true}}' >/dev/null
BACKUP_PODS="app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/name=$(jp '{.spec.template.metadata.labels.app\.kubernetes\.io/name}')-backup"
for _ in $(seq 360); do
  [ -z "$($K get pods -l "$BACKUP_PODS" --field-selector=status.phase=Running -o name)" ] && break; sleep 5
done
[ -z "$($K get pods -l "$BACKUP_PODS" --field-selector=status.phase=Running -o name)" ] || { echo "a backup is still running; retry later" >&2; exit 1; }

$K scale deploy "$DEPLOY" --replicas=0
$K wait --for=delete pod -l "$SEL" --timeout=300s 2>/dev/null || [ -z "$($K get pods -l "$SEL" -o name)" ]
$K delete job "$JOB" --ignore-not-found
$K apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      imagePullSecrets: $PULL
      tolerations: $TOL
      nodeSelector: $NODESEL
      affinity: $AFF
      securityContext: $SEC
      containers:
        - name: restore
          image: $IMAGE
          env: [{name: BACKUP, value: $BACKUP}]
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          command:
            - node
            - -e
            - |
              const fs = require('fs');
              const src = '/backup/' + process.env.BACKUP;
              if (!fs.existsSync(src + '/COMPLETE')) throw new Error('not a complete backup: ' + src);
              const aside = '/data/pre-restore-' + new Date().toISOString().replace(/[-:.]/g, '');
              fs.mkdirSync(aside);
              for (const f of ['relaycast.db', 'relaycast.db-wal', 'relaycast.db-shm', 'relaycast-files']) {
                if (fs.existsSync('/data/' + f)) fs.renameSync('/data/' + f, aside + '/' + f);
              }
              fs.copyFileSync(src + '/relaycast.db', '/data/relaycast.db');
              if (fs.existsSync(src + '/relaycast-files')) fs.cpSync(src + '/relaycast-files', '/data/relaycast-files', { recursive: true });
              else fs.mkdirSync('/data/relaycast-files');
              console.log(JSON.stringify({ restored: process.env.BACKUP, previous: aside }));
          volumeMounts:
            - {name: data, mountPath: /data}
            - {name: backup, mountPath: /backup, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: $DATA_CLAIM}}
        - {name: backup, persistentVolumeClaim: {claimName: $BACKUP_CLAIM, readOnly: true}}
        - {name: tmp, emptyDir: {sizeLimit: 64Mi}}
EOF
if ! $K wait --for=condition=complete "job/$JOB" --timeout=600s; then
  $K logs "job/$JOB" 2>/dev/null || true
  if [ -z "$($K get job "$JOB" -o jsonpath='{.status.startTime}')" ] \
    || [ -n "$($K get pods -l "job-name=$JOB" --field-selector=status.phase=Pending -o name)" ]; then
    # The restore never ran (unschedulable or image pull): nothing was moved.
    $K delete job "$JOB" --ignore-not-found
    $K scale deploy "$DEPLOY" --replicas=1
    echo "restore Job never ran; the original data is untouched and the Deployment is back at 1 replica" >&2
  else
    echo "restore failed after starting; the Deployment stays at 0 replicas. The previous data is under /data/pre-restore-* on $DATA_CLAIM" >&2
  fi
  exit 1
fi
$K logs "job/$JOB"
$K delete job "$JOB"
$K scale deploy "$DEPLOY" --replicas=1
$K rollout status deploy "$DEPLOY" --timeout=300s
