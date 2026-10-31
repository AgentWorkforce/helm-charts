#!/usr/bin/env bash
# Restore a Relaycast release from a backup written by the chart's backup
# CronJob. Usage:
#   NS=relaycast RELEASE=relaycast BACKUP=relaycast-<UTC timestamp> ci/relaycast/restore.sh
# The engine is stopped for the copy. The replaced database and files are
# moved to /data/pre-restore-<ts>/ on the data volume, never deleted.
set -euo pipefail
: "${NS:?set NS}" "${RELEASE:?set RELEASE}" "${BACKUP:?set BACKUP (a relaycast-<timestamp> directory)}"
[[ "$BACKUP" =~ ^relaycast-[0-9]{8}T[0-9]{6}Z$ ]] || { echo "BACKUP must look like relaycast-20260101T000000Z" >&2; exit 2; }
K="kubectl -n $NS"
SEL="app.kubernetes.io/name=relaycast,app.kubernetes.io/instance=$RELEASE"
DEPLOY=$($K get deploy -l "$SEL" -o jsonpath='{.items[0].metadata.name}')
IMAGE=$($K get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
DATA_CLAIM=$($K get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
BACKUP_CLAIM=$($K get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.volumes[?(@.name=="backup")].persistentVolumeClaim.claimName}')
[ -n "$BACKUP_CLAIM" ] || { echo "release $RELEASE has no backup volume (backup.enabled=false)" >&2; exit 2; }
JOB="$DEPLOY-restore"

$K scale deploy "$DEPLOY" --replicas=0
$K wait --for=delete pod -l "$SEL" --timeout=300s
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
      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000, seccompProfile: {type: RuntimeDefault}}
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
  $K logs "job/$JOB" || true
  echo "restore failed; the Deployment is left at 0 replicas and the data volume untouched or moved aside under /data/pre-restore-*" >&2
  exit 1
fi
$K logs "job/$JOB"
$K delete job "$JOB"
$K scale deploy "$DEPLOY" --replicas=1
$K rollout status deploy "$DEPLOY" --timeout=300s
