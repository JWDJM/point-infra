# ADR-0023: AWS Terraform 을 dev / prod 환경 × 계층별 state 로 분리하고 dev VPC 에 10.11.0.0/16 배정
- 상태: **Proposed**
- 날짜: 2026-11-27 KST
- 대체: 없음. 아래 두 문서의 확정 사항을 바꾼다
  - `04-infrastructure/terraform-guide.md` 1장(디렉터리 구조)·2장(State 전략)의 `envs/aws-main` 단일 환경
  - `01-architecture/network-design.md` 1장 CIDR 표 (AGENTS Decision Lock "네트워크") — AWS 대역 추가
- 관련: ADR-0009 (Terraform / ArgoCD 역할 분리), ADR-0010 (DR 독립성), ADR-0022 (노드 풀 분리)
- 논의: #49

## 맥락
- AWS 쪽 Terraform 환경이 `envs/aws-main` 하나뿐이다. 설정 변경(노드 풀, DB 파라미터, 모듈 버전)을 미리 검증할 곳이 없어
  운영 환경에 바로 적용해야 한다.
- `aws-main` 은 state 가 1개다. 학습 기간에는 비용 때문에 작업이 끝나면 destroy 하는데(terraform-guide 6장),
  비싼 EKS 만 지우고 싶어도 VPC·RDS·Redis 가 같은 state 에 묶여 있어 `-target` 으로 골라 지워야 한다. 실수하면 DB 까지 지워진다.
- 운영 설계(Multi-AZ, 삭제 보호, AZ별 NAT)와 학습용 설정(단일 AZ, 삭제 보호 끔, NAT 1개)이 같은 코드의 변수 기본값으로 섞여 있다.
- CIDR 표에 AWS 대역이 `10.10.0.0/16` 하나뿐이다. dev VPC 를 같은 대역으로 만들면 동작은 하지만
  GCP DR VPN(`10.20.0.0/16` 등)에 dev 를 붙일 수 없고, 두 VPC 를 연결해야 할 때(피어링·VPN) 대역이 겹친다.
- PoC(point-terraform)는 이미 계층별 state(`10-network / 20-data / 30-cluster`)로 나눠 매일 30 만 지우는 방식을 쓰고 있고,
  2026-11-27 에 이를 `envs/{dev,prod}/<계층>` + `modules/` 로 확장했다.

## 결정
**AWS Terraform 을 환경(dev, prod) × 계층(network, data, cluster) 별 root 로 나누고, 리소스 코드는 모듈 한 벌을 공유한다.
dev VPC 는 예약 대역의 첫 번째인 `10.11.0.0/16` 을 쓴다.**

### 1. 디렉터리
```
infra/terraform/
├── bootstrap/{aws,gcp}/          (변경 없음) state 버킷 — aws 버킷 1개를 dev·prod 가 함께 쓴다 (key 로 구분)
├── global/aws/ecr/               ECR (dev·prod 공용) — dev 에서 검증한 같은 이미지 태그를 prod 에 배포
├── modules/aws/                  리소스 코드 한 벌. provider·backend 없음 (기존 규칙)
│   ├── network/                  (← vpc)       VPC, 서브넷, NAT, VPC Endpoint
│   ├── data/                     (← rds, elasticache) KMS, RDS, Redis, SG, Secrets Manager 칸
│   ├── cluster/                  (← eks, karpenter) EKS, 노드그룹, 애드온, SG rule, Pod Identity, Karpenter AWS 쪽
│   ├── waf/  argocd-bootstrap/   (기존 계획 그대로)
└── envs/
    ├── aws-dev/{10-network,20-data,30-cluster}/    얇은 root: module 호출 + 환경별 값, backend, remote state, output
    ├── aws-prod/{10-network,20-data,30-cluster}/   (← aws-main)
    ├── gcp-dr-standby/  gcp-dr-compute/            (변경 없음)
```
- 환경 이름 `aws-dev`, `aws-prod` 는 기존 `gcp-dr-*` 처럼 클라우드 접두사를 붙인다.
- 계층 번호(10/20/30)는 apply 순서이자 의존 방향이다. 위 계층만 아래 계층을 읽는다.
- 이름 접두사: `point-dev-*`, `point-prod-*` (클러스터 `point-<env>-eks`, 비밀 `point-<env>/core-service`). `point-main-*` 은 `point-prod-*` 로 바꾼다.

### 2. State
| root | backend key | 지우는 주기 |
|---|---|---|
| `global/aws/ecr` | `aws/global/ecr/terraform.tfstate` | 거의 안 지움 |
| `envs/aws-<env>/10-network` | `aws/<env>/network/terraform.tfstate` | 환경 전체 정리 때 |
| `envs/aws-<env>/20-data` | `aws/<env>/data/terraform.tfstate` | 환경 전체 정리 때 (prod 는 삭제 보호) |
| `envs/aws-<env>/30-cluster` | `aws/<env>/cluster/terraform.tfstate` | dev 는 매일 가능 (ALB·Karpenter 노드 정리 후) |

- `terraform_remote_state` 는 **같은 환경의 AWS 계층끼리만** 쓴다 (data → network, cluster → network·data).
  GCP(`gcp-dr-*`)는 AWS state 를 읽지 않는다 — ADR-0010 과 terraform-guide 2장의 "환경 간 remote_state 금지" 취지를 그대로 지킨다.
- 위 계층이 읽는 output 은 계층의 "공개 API" 로 취급한다. 이름을 바꾸면 위 계층이 깨지고, 비밀값은 output 에 넣지 않는다.

### 3. 환경별 값 (`envs/aws-<env>/<계층>/main.tf` 의 module 인자에만 둔다)
| 항목 | dev | prod |
|---|---|---|
| VPC | `10.11.0.0/16` | `10.10.0.0/16` (기존) |
| NAT | 1개 | AZ별 |
| RDS | 단일 AZ, 삭제 보호 끔, 마지막 스냅샷 없음, 백업 1일 | Multi-AZ, 삭제 보호, 마지막 스냅샷, 백업 7일 (ADR-0013) |
| Redis | 1노드 | 2노드 Multi-AZ + 자동 장애 조치 (ADR-0019) |
| Secrets Manager 복구 기간 / KMS 삭제 대기 | 0일 / 7일 | 7일 / 30일 |
| EKS 로그 보관 | 7일 | 30일 |
| NodePool 상한 (general / event / monitoring, ADR-0022) | 작게 (PoC: 8 / 16 / 4 vCPU) | 운영 값 (PoC: 32 / 400 / 16 vCPU) |
| KEDA event-service 최대 | 작게 (PoC: 10) | 운영 값 (100) |

### 4. CIDR (network-design.md 1장 표 변경)
| 환경 | 대역 | 용도 |
|---|---|---|
| AWS Main VPC → **AWS Prod VPC** | `10.10.0.0/16` | 운영 (변경 없음) |
| **AWS Dev VPC** | **`10.11.0.0/16`** | 개발·검증 (신규) |
| GCP DR VPC, GKE, PSA, 로컬 | (변경 없음) | |
| 예약 (향후 리전 확장) | `10.11.0.0/16` ~ `10.19.0.0/16` → **`10.12.0.0/16` ~ `10.19.0.0/16`** | |

- dev 서브넷은 prod 와 같은 모양에 두 번째 자리만 11: Public `10.11.0~2.0/24`, Private-App `10.11.32/64/96.0/19`, Private-Data `10.11.128~130.0/24`.
- **`10.10` 을 유지하는 이유:** 두 번째 자리로 클라우드·용도를 구분하는 기존 체계(10.1x = AWS, 10.2x~10.3x = GCP)를 지키고,
  AWS 콘솔 마법사·튜토리얼의 기본값이라 가장 겹치기 쉬운 `10.0.0.0/16` 을 피한다. 배포 전이라 바꿀 비용은 작지만 얻는 이득도 없다.
- dev 대역이 prod·GCP 와 겹치지 않으므로, 필요하면 dev 를 GCP DR VPN 에 붙여 논리 복제(ADR-0020)를 리허설할 수 있다.
  기본 운영은 **prod 만 VPN 연결**이다.

### 5. K8s (ADR-0009 경계는 그대로)
- `k8s/overlays/aws` → `k8s/overlays/aws-dev`, `k8s/overlays/aws-prod`. 두 환경 공통 부분(ExternalSecret, Gateway, ConfigMap)은
  Kustomize Component 로 묶고, overlay 에는 환경 차이(KEDA 상한, 비밀 이름 접두사)만 둔다. `overlays/gcp-dr` 은 변경 없음.
- 클러스터마다 ArgoCD 가 자기 환경의 overlay 와 NodePool 값을 바라본다 (`k8s/argocd/aws` → 환경별 Application).

## 고려한 대안
| 대안 | 장점 | 단점 | 기각 이유 |
|---|---|---|---|
| **A. 환경 × 계층 root + 공유 모듈** | 환경 차이가 경로와 `main.tf` 에 보인다. 계층별로 지울 수 있다. 코드는 한 벌 | root 파일(providers·variables·outputs)이 환경 × 계층(6벌)만큼 반복. 계층을 건너는 변경은 apply 두 번 | **채택** |
| B. 환경마다 root 하나 (`envs/aws-dev`, `envs/aws-prod`) | 구조가 단순, 지금 `aws-main` 과 같은 모양 | EKS 만 지우려면 `-target`. DB 와 클러스터가 같은 plan 에 나온다 | 맥락의 state 문제를 그대로 둔다 |
| C. 같은 폴더 + `-var-file` + `-backend-config` 로 환경 전환 | 폴더가 늘지 않는다 | init 을 잘못하면 dev 값으로 prod state 에 apply. "지금 어느 환경인가" 가 경로에 안 보인다 | 사고 위험 |
| D. Terraform workspace | state 만 나뉘고 코드 한 벌 | 값 분기가 `terraform.workspace` 조건문으로 코드에 퍼진다. 현재 workspace 착각 위험 | C 와 같은 이유 |
| E. Terragrunt | 반복 파일을 줄인다 | 도구가 하나 늘고 팀이 배워야 한다 | 계층 3개 × 환경 2개 규모에선 과함 |
| F. dev 도 `10.10.0.0/16` | CIDR 표를 바꾸지 않는다 (Decision Lock 유지) | dev 를 VPN·피어링에 붙일 수 없다 | 대역은 지금 정하지 않으면 나중에 VPC 재생성이 필요 |
| G. prod `10.0.0.0/16`, dev `10.1.0.0/16` | 숫자가 깔끔하다 | 가장 흔한 기본 대역이라 외부망과 겹치기 쉽다. 기존 번호 체계·문서를 모두 바꿔야 한다 | 이득이 보기 좋은 숫자뿐 |

## 결과
- 긍정
  - 운영에 가기 전에 dev 에서 같은 모듈 코드를 검증한다. 환경 차이는 `main.tf` 의 값뿐이라 리뷰가 쉽다.
  - dev 는 `30-cluster` 만 매일 지워 비용을 줄이고, DB·VPC 는 다른 state 라 실수로 지워지지 않는다.
  - prod 에만 삭제 보호·Multi-AZ·백업을 켜서 운영 설계(ADR-0013, 0019)를 코드 기본값과 섞지 않고 명시한다.
  - dev 대역이 분리돼 VPN·피어링 확장 여지가 생긴다.
- 부정
  - 폴더와 `terraform init` 이 늘어난다 (AWS root 1개 → 7개). CI plan 워크플로도 root 마다 돌아야 한다.
  - dev 가 상시 떠 있으면 비용이 두 배에 가까워진다 → dev 는 작업할 때만 올리는 것을 기본으로 한다.
  - `aws-main` / `point-main-*` 을 참조하던 곳(ArgoCD Application, LBC `vpcTags`, 문서)을 모두 바꿔야 한다.
  - Decision Lock "네트워크" 행이 바뀐다 → AGENTS 공통 규칙 동기화가 필요하다.
- 검증: point-terraform(PoC)에 같은 구조를 먼저 만들었다 (`modules/{network,data,cluster}`, `envs/{dev,prod}/{10-network,20-data,30-cluster}`, `global/ecr`).
  `terraform validate`(일부), `kubectl kustomize`(dev·prod) 까지 확인했고 apply 는 아직이다.
  PoC 는 dev 도 `10.10.0.0/16` 으로 만들어 두었으므로 이 ADR 에 맞춰 `10.11.0.0/16` 으로 바꾼다.
- 후속 과제 (승인 후)
  - 문서: `terraform-guide.md` 1·2·5·6장, `network-design.md` 1·2장(dev 서브넷 표 추가), `infra/terraform/README.md`, AGENTS Decision Lock "네트워크" 행 → `team/ai/AGENTS.common.md` 버전 올리고 동기화
  - Terraform: `envs/aws-main` → `envs/aws-prod/{10,20,30}` + `envs/aws-dev/{10,20,30}`, 모듈 재편(`vpc`→`network`, `rds`+`elasticache`→`data`, `eks`+`karpenter`→`cluster`), `global/aws/ecr`
  - K8s: `overlays/aws` → `aws-dev` / `aws-prod`, `k8s/argocd/aws` Application 환경별 분리
  - CI: plan 워크플로를 root 별로, prod apply 는 승인 단계 추가
  - 문서·코드의 `point-main` 이름 → `point-prod`
