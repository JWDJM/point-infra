#!/usr/bin/env bash
set -euo pipefail
# TODO: gcloud container clusters get-credentials ... && for d in core-service point-query; do kubectl -n point rollout status deploy/$d --timeout=10m; done
#   (DB 를 쓰는 서비스는 db-migration Job 성공 후 wave 1 로 배포된다 — ADR-0024)
echo "TODO: wait for core-service, point-query ready"
