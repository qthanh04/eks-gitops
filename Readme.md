````markdown
# README — Triển khai từ đầu: EKS + AWS Load Balancer Controller + Argo CD + Helm (GitOps)

Tài liệu này hướng dẫn **từ con số 0** đến khi ứng dụng **BE Nemi** chạy trên **EKS** và **Argo CD** tự đồng bộ từ Git (Helm chart).

---



## 0) Tiền đề & công cụ.

- Đã cài: **AWS CLI**, **kubectl**, **eksctl**, **helm**, **git** (tuỳ chọn: `gh`), (tuỳ chọn) **argocd** CLI.
- Tài khoản AWS có quyền tạo EKS, IAM, VPC, ELB, ACM…
- Đã có **SSH key** trong EC2 (ví dụ `kube-demo`) nếu muốn SSH vào node.

Thiết lập biến môi trường (đổi lại theo của bạn)::

```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=eksdemo1
export NODEGROUP_NAME=eksdemo1-ng-private1
export KEY_NAME=kube-demo   # Tên SSH public key trên EC2
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
````

---

## 1) Tạo EKS **không** kèm nodegroup (để tự quản lý node)

```bash
eksctl create cluster \
  --name=${CLUSTER_NAME} \
  --region=${AWS_REGION} \
  --zones=ap-southeast-1a,ap-southeast-1b \
  --without-nodegroup

# Kiểm tra (chưa có node)
kubectl get nodes
eksctl get cluster --name=${CLUSTER_NAME}
```

---

## 2) Tạo Managed Nodegroup (private)

```bash
eksctl create nodegroup \
  --cluster=${CLUSTER_NAME} \
  --region=${AWS_REGION} \
  --name=${NODEGROUP_NAME} \
  --node-type=t3.medium \
  --nodes-min=1 \
  --nodes-max=4 \
  --node-volume-size=20 \
  --ssh-access \
  --ssh-public-key=${KEY_NAME} \
  --managed \
  --asg-access \
  --external-dns-access \
  --full-ecr-access \
  --appmesh-access \
  --alb-ingress-access \
  --node-private-networking

# Kiểm tra node đã lên
kubectl get nodes -o wide
```

> Gợi ý: Nếu ALB không tạo được về sau, nhớ kiểm tra **tags của Subnet** (public: `kubernetes.io/role/elb=1`, internal: `kubernetes.io/role/internal-elb=1`, và `kubernetes.io/cluster/${CLUSTER_NAME}=shared`).

---

## 3) Bật IAM OIDC Provider (IRSA)

```bash
eksctl utils associate-iam-oidc-provider \
  --region ${AWS_REGION} \
  --cluster ${CLUSTER_NAME} \
  --approve
```

---

## 4) Tạo IAM Policy + ServiceAccount cho **AWS Load Balancer Controller**

Tạo policy theo tài liệu chính thức:

```bash
curl -o iam_policy_latest.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy_latest.json
```

Tạo **serviceAccount** (IRSA) kèm policy:

```bash
eksctl create iamserviceaccount \
  --cluster=${CLUSTER_NAME} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve
```

---

## 5) Cài **AWS Load Balancer Controller** bằng Helm

Lấy `VPC_ID` từ cluster & cài đặt:

```bash
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
echo "VPC_ID=${VPC_ID}"

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${CLUSTER_NAME} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=${AWS_REGION} \
  --set vpcId=${VPC_ID} \
  --set image.repository=public.ecr.aws/eks/aws-load-balancer-controller

# Kiểm tra
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
```

---

## 6) Tạo **IngressClass** cho ALB

```bash
cat > 01-ingressclass.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: my-aws-ingress-class
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: ingress.k8s.aws/alb
YAML
```

Nếu có sẵn rồi thì
```
kubectl apply -f 01-ingressclass.yaml
```


---

## 7) Cài **Argo CD** vào cluster

Cách nhanh bằng Helm (demo):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Lấy UI endpoint & mật khẩu:

```bash
kubectl -n argocd get svc argocd-server
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

> Prod: dùng **Ingress + TLS/SSO**, *không* để server trần HTTP/LoadBalancer lâu dài.

---

## 8) Tạo **Argo CD Application** trỏ tới chart

Tạo file `argocd/boostrap.yaml` (đổi `repoURL` + `path` theo repo của bạn hoặc dùng clone từ repo về):

```bash
mkdir -p argocd
cat > argocd/app-srs-nemi-tool.yaml <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: srs-nemi-tool
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPO>.git'
    targetRevision: main
    path: charts/srs-nemi-tool
    helm:
      releaseName: srs-nemi-tool
  destination:
    server: "{{ .Values.path }}"
    namespace: srs-nemi-tool
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
YAML
```

Áp dụng Application:


```bash
kubectl apply -f argocd/boostrap.yaml
```

---

## 10) Push repo lên GitHub (khuyến nghị GitOps)

```bash
git init
git add .
git commit -m "feat: gitops bootstrap (chart + argocd app)"
git branch -M main
# Tạo repo trống trên GitHub rồi:
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/<YOUR_REPO>.git
git push -u origin main
```

> Nếu repo private, vào Argo CD → **Settings → Repositories** thêm credentials (hoặc `argocd repo add ...` bằng CLI).

---

## 11) Kiểm tra & truy cập ứng dụng

```bash
# Trạng thái Argo CD Application
kubectl -n argocd get applications.argoproj.io srs-nemi-tool -o wide

# Resource trong namespace đích
kubectl -n srs-nemi-tool get all
kubectl -n srs-nemi-tool get ingress
```

* Vào AWS Console → EC2 → **Load Balancers** kiểm tra ALB đã tạo.
* Lấy DNS của ALB từ object Ingress (`ADDRESS`) rồi truy cập trình duyệt.

---

## 12) Cập nhật ứng dụng (GitOps Workflow)

* Sửa `charts/srs-nemi-tool/values.yaml` (ví dụ đổi `image.tag`), commit & push:

  ```bash
  git commit -am "chore: bump image tag to vX.Y.Z"
  git push
  ```
* Argo CD sẽ tự detect, sync, và rollout bản mới (đã bật `automated.prune/selfHeal`).

---

## 13) Troubleshooting nhanh

* **ALB không tạo**: kiểm tra subnet tags, IAM policy, log:

  ```bash
  kubectl -n kube-system logs deployment/aws-load-balancer-controller
  ```
* **Service không có endpoint**: pod crash/Readiness fail → `kubectl -n srs-nemi-tool describe pod ...`
* **ImagePullBackOff**: kiểm tra quyền ECR (node role đã có `--full-ecr-access`), hoặc pull secret nếu registry private khác.
* **Argo CD “OutOfSync”**: sai `repoURL/targetRevision/path` hoặc repo private chưa cấp quyền.

---

## 14) Dọn dẹp

```bash
# Xoá app (giữ Argo CD)
kubectl -n argocd delete application srs-nemi-tool

# Gỡ Argo CD
helm -n argocd uninstall argocd
kubectl delete ns argocd

# Xoá cluster (cẩn thận, chi phí!)
eksctl delete cluster --name=${CLUSTER_NAME} --region=${AWS_REGION}
```

---

## Ghi chú bảo mật & best practices

* Dùng **Ingress + TLS** cho Argo CD server, bật **SSO/OIDC** (tắt admin mặc định).
* Không commit **secrets** lên Git: dùng **External Secrets Operator** (AWS Secrets Manager) hoặc **SOPS + KMS**.
* Tách môi trường **dev/stg/prod** bằng **AppProject** + nhiều `Application` + `values-*.yaml`.
* Bật **prune + selfHeal** (đã có trong ví dụ) để đảm bảo drift-free.

---

```
```
