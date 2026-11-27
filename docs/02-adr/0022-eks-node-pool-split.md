# ADR-0022: EKS 노드 풀을 system / general / event / monitoring 4개로 분리
- 상태: **Proposed**
- 날짜: 2026-11-27 KST
- 대체: 없음 (ADR-0002 의 "core = Managed NodeGroup On-Demand / event = Karpenter Spot" 을 세분화한다)
- 관련: ADR-0002 (EKS + Karpenter), ADR-0009 (Terraform / ArgoCD 역할 분리), #19 (관측성 도구 선정)
- 논의: #47

## 맥락
- 지금 AWS 구조는 노드 풀이 2개다.
  - `core` Managed NodeGroup (On-Demand, `workload=core`) — **컨트롤러와 앱이 함께** 뜬다:
    CoreDNS, metrics-server, LBC, External Secrets, KEDA, Karpenter + core-service, web
  - `event` Karpenter NodePool (Spot 우선, `workload=event` taint) — event-service 만
- 컨트롤러와 앱이 같은 노드 자원을 나눠 쓴다. core-service 의 부하·배포·OOM 이 Karpenter·CoreDNS 에 영향을 줄 수 있고,
  Karpenter 가 영향을 받으면 이벤트 시간대의 노드 확장 자체가 늦어진다.
- 앱이 늘어나면 컨트롤러 용량까지 고려해 core MNG 의 크기를 손으로 조정해야 한다
  (PoC 에서 t3.medium 2대로 빠듯해 3대로 올렸다).
- 모니터링 스택(#19 에서 선정 중)을 어느 노드에 올릴지 정해져 있지 않다.
  Prometheus 는 메모리를 많이 쓰고, EBS PVC 로 특정 AZ 에 묶인다.

## 결정
**노드 풀을 4개로 나눈다. 컨트롤러 전용 `system` 만 Managed NodeGroup 이고, 나머지 3개는 Karpenter NodePool 이다.**

| 풀 | 만드는 곳 | 용량 | 라벨 / taint | 올라가는 것 |
|---|---|---|---|---|
| system | Terraform (EKS MNG) | On-Demand | `workload=system` / `CriticalAddonsOnly=true:NoSchedule` | CoreDNS, metrics-server, LBC, ESO, KEDA, Karpenter |
| general | Karpenter NodePool | On-Demand | `workload=general` / 없음 | core-service, web |
| event | Karpenter NodePool (기존) | Spot 우선 (부족하면 On-Demand) | `workload=event` / `workload=event:NoSchedule` | event-service |
| monitoring | Karpenter NodePool | On-Demand | `workload=monitoring` / `workload=monitoring:NoSchedule` | 모니터링 스택 (#19) |

- **system 만 MNG 인 이유:** Karpenter 가 자기가 만든 노드에 뜨면, 그 노드가 회수·통합될 때 Karpenter 도 같이 내려간다.
  Karpenter 와 클러스터 필수 애드온은 Karpenter 와 무관하게 항상 있는 노드에 있어야 한다.
- **general 에 taint 를 걸지 않는 이유:** 나머지 3개 풀은 taint 로 막혀 있으므로, nodeSelector·toleration 이 없는 앱 파드는
  자연히 general 로 온다. core-service·web 매니페스트를 바꾸지 않아도 된다.
- **general·monitoring 을 On-Demand 로 두는 이유:** 상시 서비스와 관측 도구는 Spot 회수로 끊기면 안 된다.
  장애가 났을 때 모니터링까지 같이 죽으면 원인을 볼 수 없다. Spot 은 짧고 몰리는 트래픽을 받는 event 만 쓴다 (ADR-0002).
- **monitoring 의 disruption 은 `WhenEmpty`:** EBS PVC 가 AZ 에 묶여 있어서, "덜 쓴다"는 이유로 노드를 옮기면 같은 AZ 에
  노드가 다시 떠야 파드가 뜬다. 비었을 때만 회수한다. 모니터링 파드가 생기기 전에는 노드가 0대라 비용이 없다.
- **컨트롤러 고정 방법:** 각 컨트롤러에 `nodeSelector {workload: system}` + toleration `CriticalAddonsOnly` 를 넣는다.
  CoreDNS·metrics-server EKS 애드온과 Karpenter 차트는 이 toleration 을 기본값으로 갖고 있어서 nodeSelector 만 더한다.
- **역할 분리는 ADR-0009 그대로:** system MNG 는 Terraform, NodePool 3개와 EC2NodeClass 는 `k8s/platform/karpenter` (ArgoCD).

## 고려한 대안
| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| **A. system=MNG + general·event·monitoring=Karpenter NodePool** | 컨트롤러와 앱 격리, Terraform 변경은 MNG 하나, 앱 노드는 파드 수에 맞춰 자동 증감 | 상시 노드가 늘어난다 (system 2 + general 1~2) | **채택** |
| B. 4개 모두 MNG (event 만 Spot MNG) | 노드 수를 예측하기 쉽다 | MNG 는 Pending 파드에 맞춰 빠르게 늘지 않는다. Karpenter 를 고른 이유(ADR-0002)와 맞지 않는다 | ADR-0002 와 충돌 |
| C. 지금처럼 core MNG 1개 + event | 노드 수가 가장 적다 | 컨트롤러와 앱이 섞여 서로 영향을 준다. 모니터링 자리가 없다 | 맥락의 문제를 그대로 둔다 |
| D. A 에서 monitoring 을 system 풀에 함께 | 노드 1대 절약 | Prometheus 메모리 사용이 Karpenter·CoreDNS 를 압박한다. 모니터링 규모에 따라 system MNG 크기를 손으로 조정해야 한다 | PoC 에서는 고려할 만하지만 기본안으로는 기각 |
| E. general 도 Spot 허용 | 비용 절감 | Spot 회수 때 core-service(원장·로그인)가 재배치된다. PDB 가 있어도 2분 예고 안에 옮겨야 한다 | 상시 서비스 안정성 우선 |

## 결과
- 긍정
  - Karpenter·CoreDNS 등 컨트롤러가 앱 부하와 분리된다 → 이벤트 시간대 확장 경로가 안정된다.
  - 앱 노드(general)는 Karpenter 가 파드 수에 맞춰 늘리고 줄인다. MNG 크기를 손으로 조정할 일이 줄어든다.
  - 모니터링 스택(#19)을 올릴 자리가 정해진다. 스택 쪽에는 nodeSelector + toleration 만 넣으면 된다.
- 부정
  - 상시 노드 수가 늘어난다 (core 2~3대 → system 2 + general 1~2). 노드당 고정 비용(DaemonSet, ENI)도 늘어난다.
  - 컨트롤러 Helm values 마다 nodeSelector·toleration 을 넣어야 한다. 빠뜨리면 그 컨트롤러가 Pending 이 된다.
  - core 노드를 쓰던 클러스터에서는 옮기는 순서가 필요하다 (system 먼저 추가 → core drain → core 삭제).
    MNG 키 이름만 바꾸면 노드그룹이 지워졌다 다시 만들어져 서비스가 끊긴다.
- 검증: point-terraform(PoC)에 먼저 반영했다 (`30-cluster/eks.tf`, `k8s/platform/karpenter/nodepool-{general,event,monitoring}.yaml`,
  `ec2nodeclass.yaml`, 컨트롤러 values). 아직 apply 전이다.
- 후속 과제 (승인 후, point-infra 에서)
  - `infra/terraform/modules/aws/eks`: `core` → `system` MNG (taint, 라벨), coredns·metrics-server 애드온 nodeSelector
  - `infra/terraform/modules/aws/karpenter`: Helm release values 에 `nodeSelector {workload: system}`
  - `k8s/platform/karpenter`: `nodepool-general.yaml`, `nodepool-monitoring.yaml` 추가, EC2NodeClass 를 별도 파일로
  - LBC·ESO·KEDA ArgoCD Application values 에 nodeSelector·toleration
  - 문서: `01-architecture/architecture-overview.md` (core-service 노드 표기), `08-project-management/roadmap.md`,
    `05-operations/finops.md`, `00-overview/implementation-status.md`
  - GCP(DR, ADR-0003) 쪽 GKE 노드 풀은 범위 밖이다. Pilot Light 라 필요해지면 따로 결정한다.
