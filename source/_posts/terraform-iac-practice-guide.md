---
title: Terraform基础设施即代码实战指南
date: 2026-06-20 08:00:00
tags:
  - DevOps
  - Terraform
  - IaC
  - 云原生
  - 基础设施
categories:
  - DevOps
author: 东哥
---

# Terraform基础设施即代码实战指南

Terraform作为HashiCorp推出的基础设施即代码（Infrastructure as Code）工具，已经成为云原生领域管理云资源的事实标准。本文从实践角度出发，深入讲解Terraform的核心概念、模块化设计、状态管理、CI/CD集成以及生产级最佳实践。

## 一、Terraform核心架构

### 1.1 工作流程

```text
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  编写配置      │ → │   terraform  │ → │  terraform   │
│  *.tf文件      │   │   init       │   │   plan       │
└──────────────┘    └──────────────┘    └──────┬───────┘
                                               ↓
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  资源管理     │ ← │  terraform   │ ← │  terraform   │
│  增删改查     │    │  apply       │    │   validate   │
└──────────────┘    └──────────────┘    └──────────────┘
```

### 1.2 Terraform vs 其他IaC工具

| 特性 | Terraform | AWS CDK | Pulumi | Ansible |
|-----|----------|---------|--------|---------|
| 声明式/命令式 | 声明式(HCL) | 命令式(TS/Python) | 命令式(TS/Go) | 声明式(YAML) |
| 状态管理 | 核心功能 | 需要 | 需要 | 无需 |
| Provider生态 | 2000+ | AWS为主 | 多云 | 配置管理 |
| 执行模型 | 请求-响应 | CloudFormation | 自管理 | 推送/Pull |
| Learning Curve | 中等 | 中等 | 中等 | 低 |
| 并行执行 | 自动 | 自动 | 自动 | 需配置 |
| 不可变基础设施 | ✅ | ✅ | ✅ | ✅ |

## 二、项目结构设计

### 2.1 标准项目结构

```
terraform-project/
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf         # S3/OSS后端配置
│   ├── staging/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── backend.tf
│   └── prod/
│       ├── main.tf
│       ├── variables.tf
│       ├── terraform.tfvars
│       └── backend.tf
├── modules/
│   ├── vpc/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── ecs/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── rds/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── global/
│   ├── iam/
│   │   └── main.tf
│   └── dns/
│       └── main.tf
├── provider.tf                 # Provider配置
├── backend.tf                  # 远端状态存储
├── versions.tf                 # Terraform版本约束
└── Makefile                    # 常用命令封装
```

### 2.2 版本约束

```hcl
# versions.tf
terraform {
  required_version = ">= 1.5, < 2.0"
  
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.200.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
  }
}
```

## 三、Provider配置

```hcl
# provider.tf
provider "alicloud" {
  region = var.region
  
  # 通过环境变量获取凭证
  # export ALICLOUD_ACCESS_KEY="xxx"
  # export ALICLOUD_SECRET_KEY="xxx"
  # 或使用RAM Role
  assume_role {
    role_arn     = var.role_arn
    session_name = "terraform-deploy"
  }
}

provider "kubernetes" {
  # 从ACK/ASK集群获取kubeconfig
  config_path = "~/.kube/config"
  
  # 或使用阿里云认证
  # alias = "alicloud-k8s"
  # config_context = "alicloud-k8s"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}
```

### 3.1 Provider别名多区域部署

```hcl
# 多区域阿里云Provider
provider "alicloud" {
  alias   = "cn-beijing"
  region  = "cn-beijing"
}

provider "alicloud" {
  alias   = "cn-hangzhou"
  region  = "cn-hangzhou"
}

provider "alicloud" {
  alias   = "us-west-1"
  region  = "us-west-1"
}

# 使用别名
module "vpc_beijing" {
  source = "./modules/vpc"
  providers = {
    alicloud = alicloud.cn-beijing
  }
  vpc_name   = "prod-beijing"
  vpc_cidr   = "10.1.0.0/16"
}

module "vpc_hangzhou" {
  source = "./modules/vpc"
  providers = {
    alicloud = alicloud.cn-hangzhou
  }
  vpc_name   = "prod-hangzhou"
  vpc_cidr   = "10.2.0.0/16"
}
```

## 四、模块化设计

### 4.1 VPC模块

```hcl
# modules/vpc/main.tf
variable "vpc_name" {
  description = "VPC名称"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
}

variable "azs" {
  description = "可用区列表"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "私网子网CIDR"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "公网子网CIDR"
  type        = list(string)
}

# VPC
resource "alicloud_vpc" "this" {
  vpc_name   = var.vpc_name
  cidr_block = var.vpc_cidr
}

# 公网子网
resource "alicloud_vswitch" "public" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = alicloud_vpc.this.id
  cidr_block        = var.public_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  vswitch_name      = "${var.vpc_name}-public-${count.index + 1}"
}

# 私网子网
resource "alicloud_vswitch" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = alicloud_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  vswitch_name      = "${var.vpc_name}-private-${count.index + 1}"
}

# NAT网关
resource "alicloud_nat_gateway" "this" {
  vpc_id     = alicloud_vpc.this.id
  name       = "${var.vpc_name}-nat"
  nat_type   = "Enhanced"
  payment_type = "PayAsYouGo"
}

# 安全组
resource "alicloud_security_group" "this" {
  name        = var.vpc_name
  vpc_id      = alicloud_vpc.this.id
  description = "Default security group for ${var.vpc_name}"
}

# 出站规则
resource "alicloud_security_group_rule" "allow_all_tcp" {
  type              = "egress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "-1/-1"
  priority          = 1
  security_group_id = alicloud_security_group.this.id
  cidr_ip           = "0.0.0.0/0"
}

# 输出
output "vpc_id" {
  value = alicloud_vpc.this.id
}

output "public_subnet_ids" {
  value = alicloud_vswitch.public[*].id
}

output "private_subnet_ids" {
  value = alicloud_vswitch.private[*].id
}

output "security_group_id" {
  value = alicloud_security_group.this.id
}
```

### 4.2 ECS实例组模块

```hcl
# modules/ecs/main.tf
variable "name" {
  description = "ECS实例名称"
  type        = string
}

variable "instance_count" {
  description = "实例数量"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "实例规格"
  type        = string
  default     = "ecs.g7.large"
}

variable "image_id" {
  description = "镜像ID"
  type        = string
}

variable "vswitch_ids" {
  description = "虚拟交换机ID列表"
  type        = list(string)
}

variable "security_group_ids" {
  description = "安全组ID列表"
  type        = list(string)
}

variable "system_disk_size" {
  description = "系统盘大小(GB)"
  type        = number
  default     = 40
}

variable "system_disk_category" {
  description = "系统盘类型"
  type        = string
  default     = "cloud_essd"
}

# 使用for_each创建多台实例
resource "alicloud_instance" "this" {
  for_each = { for i in range(var.instance_count) : i => i }
  
  instance_name        = "${var.name}-${format("%02d", each.value + 1)}"
  host_name            = "${var.name}-${format("%02d", each.value + 1)}"
  instance_type        = var.instance_type
  image_id             = var.image_id
  vswitch_id           = var.vswitch_ids[each.value % length(var.vswitch_ids)]
  security_groups      = var.security_group_ids
  
  system_disk_category = var.system_disk_category
  system_disk_size     = var.system_disk_size
  
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = 100
  
  # UserData脚本
  user_data = <<-EOF
    #!/bin/bash
    # 初始化配置
    hostnamectl set-hostname ${var.name}-${format("%02d", each.value + 1)}
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd
  EOF
  
  tags = {
    Name      = "${var.name}-${format("%02d", each.value + 1)}"
    Env       = var.environment
    ManagedBy = "Terraform"
  }
  
  lifecycle {
    # 创建实例前先创建新的，再销毁旧的
    create_before_destroy = true
  }
}

output "instance_ids" {
  value = values(alicloud_instance.this)[*].id
}

output "private_ips" {
  value = values(alicloud_instance.this)[*].private_ip
}

output "public_ips" {
  value = values(alicloud_instance.this)[*].public_ip
}
```

## 五、状态管理

### 5.1 远程状态存储

```hcl
# backend.tf
terraform {
  backend "oss" {
    bucket  = "terraform-state-2024"
    prefix  = "env/prod"
    key     = "network/terraform.tfstate"
    region  = "cn-beijing"
    # 状态文件加密
    encrypt = true
    # ACL配置
    acl     = "private"
    # 版本控制（防误删）
    versioning = true
  }
}
```

```hcl
# 阿里云OSS后端完整配置
terraform {
  backend "oss" {
    bucket         = "my-company-terraform-state"
    prefix         = "terraform"
    key            = "production/network/terraform.tfstate"
    region         = "cn-beijing"
    encrypt        = true
    kms_key_id     = "kms-key-id"  # KMS加密
    acl            = "private"
    
    # 开启OSS Bucket的版本控制
    # 需要在OSS控制台手动开启Versioning
  }
}
```

### 5.2 状态锁

```hcl
# 使用DynamoDB实现状态锁（AWS版本）
# Terraform自动使用DynamoDB表锁
terraform {
  backend "s3" {
    bucket         = "terraform-state"
    key            = "network/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# 阿里云版 — 使用OSS的object lock + 自定义锁脚本
# 或使用Terraform Cloud的免费状态管理
```

## 六、变量与环境管理

### 6.1 变量定义

```hcl
# variables.tf
variable "environment" {
  description = "部署环境"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "region" {
  description = "阿里云区域"
  type        = string
  default     = "cn-beijing"
}

variable "instance_type" {
  description = "ECS实例规格"
  type = map(string)
  default = {
    dev     = "ecs.g7.large"      # 2C8G
    staging = "ecs.g7.xlarge"     # 4C16G
    prod    = "ecs.g7.2xlarge"    # 8C32G
  }
}

variable "tags" {
  description = "资源标签"
  type = object({
    project     = string
    environment = string
    owner       = string
    cost_center = string
  })
}
```

### 6.2 环境变量文件

```hcl
# environments/dev/terraform.tfvars
environment = "dev"
region      = "cn-beijing"

instance_type = "ecs.g7.large"

tags = {
  project     = "microservice-platform"
  environment = "dev"
  owner       = "dev-team"
  cost_center = "cc-dev-001"
}

vpc_cidr       = "10.100.0.0/16"
public_subnets  = ["10.100.1.0/24", "10.100.2.0/24"]
private_subnets = ["10.100.10.0/24", "10.100.20.0/24"]

# 开发环境最小规模
ecs_count     = 2
rds_class     = "pg.n2.small.1"   # 1C2G
redis_class   = "redis.master.small.default" # 1GB
```

```hcl
# environments/prod/terraform.tfvars
environment = "prod"
region      = "cn-beijing"

instance_type = "ecs.g7.2xlarge"

tags = {
  project     = "microservice-platform"
  environment = "prod"
  owner       = "sre-team"
  cost_center = "cc-prod-001"
}

vpc_cidr       = "10.1.0.0/16"
public_subnets  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
private_subnets = ["10.1.10.0/24", "10.1.20.0/24", "10.1.30.0/24"]

# 生产环境高可用配置
ecs_count          = 6
rds_class          = "pg.n2.4xlarge.1"    # 16C64G
rds_read_replicas  = 2                     # 只读副本
redis_class        = "redis.logic.sharding.4g.8db.0rodb.24proxy.multithread"
```

### 6.3 使用数据源

```hcl
# 使用数据源获取已有资源信息
data "alicloud_images" "ubuntu" {
  owners      = "self"
  name_regex  = "^ubuntu_24.*"
  most_recent = true
}

data "alicloud_zones" "default" {
  available_resource_creation = "VSwitch"
}

data "alicloud_resource_manager_resource_groups" "default" {
  status = "OK"
}

# 在资源中使用数据源
module "ecs" {
  source = "./modules/ecs"
  
  image_id          = data.alicloud_images.ubuntu.images[0].image_id
  vswitch_ids       = module.vpc.public_subnet_ids
  security_group_ids = [module.vpc.security_group_id]
  
  instance_type = var.instance_type[var.environment]
  instance_count = var.ecs_count
}
```

## 七、高级功能

### 7.1 Count vs for_each

```hcl
# count — 适用于简单列表
resource "alicloud_instance" "by_count" {
  count = 3
  instance_name = "app-${count.index + 1}"
  # 不能安全删除中间元素，会导致重新创建
}

# for_each — 适用于map/set，推荐使用
locals {
  instances = {
    "redis-01" = { instance_type = "ecs.g7.large", az = "cn-beijing-b" }
    "redis-02" = { instance_type = "ecs.g7.large", az = "cn-beijing-c" }
    "redis-03" = { instance_type = "ecs.g7.xlarge", az = "cn-beijing-d" }
  }
}

resource "alicloud_instance" "by_foreach" {
  for_each = local.instances
  
  instance_name  = each.key
  instance_type  = each.value.instance_type
  availability_zone = each.value.az
}
```

### 7.2 条件表达式

```hcl
# 三目条件
resource "alicloud_disk" "extra_data" {
  count = var.environment == "prod" ? var.data_disk_count : 0
  
  name       = "extra-data-${count.index + 1}"
  size       = var.environment == "prod" ? 500 : 200
  category   = var.environment == "prod" ? "cloud_essd" : "cloud_efficiency"
}

# 条件创建资源
resource "alicloud_cdn_domain" "this" {
  count = var.enable_cdn ? 1 : 0
  domain_name = var.domain_name
  cdn_type    = "web"
}

# use in variable
resource "alicloud_slb" "this" {
  # 生产环境用性能型，其他用共享型
  load_balancer_spec = var.environment == "prod" ? "slb.s3.large" : "slb.s1.small"
}
```

### 7.3 依赖关系

```hcl
# 隐式依赖（引用资源属性自动创建）
resource "alicloud_eip" "this" {
  bandwidth       = 100
  internet_charge_type = "PayByTraffic"
}

# 隐式依赖：通过引用建立
resource "alicloud_eip_association" "this" {
  allocation_id = alicloud_eip.this.id
  instance_id   = alicloud_instance.app.id
}

# 显式依赖（需要depends_on）
resource "alicloud_instance" "app" {
  # ...
  
  # 确保DNS解析记录先删除
  depends_on = [
    alicloud_alidns_record.this
  ]
}

# 模块级依赖
module "database" {
  source = "./modules/rds"
}

module "application" {
  source = "./modules/ecs"
  
  # 应用依赖数据库就绪
  depends_on = [module.database]
}
```

## 八、CI/CD集成

### 8.1 GitHub Actions

```yaml
# .github/workflows/terraform.yml
name: Terraform CI/CD

on:
  push:
    branches: [main]
    paths:
      - 'terraform/**'
  pull_request:
    paths:
      - 'terraform/**'

env:
  TF_WORKING_DIR: terraform/environments/prod

jobs:
  validate:
    name: Validate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.5.6
      
      - name: Terraform Format
        run: terraform fmt -check -recursive
        working-directory: ${{ env.TF_WORKING_DIR }}
      
      - name: Terraform Init
        run: terraform init -backend=false
        working-directory: ${{ env.TF_WORKING_DIR }}
      
      - name: Terraform Validate
        run: terraform validate
        working-directory: ${{ env.TF_WORKING_DIR }}
      
      - name: TFLint
        uses: terraform-linters/setup-tflint@v3
        with:
          tflint_version: v0.47.0
      - run: tflint --init && tflint
        working-directory: ${{ env.TF_WORKING_DIR }}
  
  plan:
    name: Plan
    needs: validate
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.5.6
      
      - name: Terraform Init
        run: terraform init
        working-directory: ${{ env.TF_WORKING_DIR }}
        env:
          ALICLOUD_ACCESS_KEY: ${{ secrets.ALICLOUD_ACCESS_KEY }}
          ALICLOUD_SECRET_KEY: ${{ secrets.ALICLOUD_SECRET_KEY }}
      
      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        working-directory: ${{ env.TF_WORKING_DIR }}
        env:
          ALICLOUD_ACCESS_KEY: ${{ secrets.ALICLOUD_ACCESS_KEY }}
          ALICLOUD_SECRET_KEY: ${{ secrets.ALICLOUD_SECRET_KEY }}
      
      - name: Comment Plan on PR
        uses: actions/github-script@v6
        if: github.event_name == 'pull_request'
        with:
          script: |
            const output = `#### Terraform Plan 📖\`${{ steps.plan.outcome }}\`
            <details><summary>Show Plan</summary>
            \`\`\`\n${{ steps.plan.outputs.stdout }}\n\`\`\`
            </details>
            *Pushed by: @${{ github.actor }}*`;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })
  
  apply:
    name: Apply
    needs: plan
    runs-on: ubuntu-latest
    environment: production
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
        with:
          terraform_version: 1.5.6
      
      - name: Terraform Init
        run: terraform init
        working-directory: ${{ env.TF_WORKING_DIR }}
        env:
          ALICLOUD_ACCESS_KEY: ${{ secrets.ALICLOUD_ACCESS_KEY }}
          ALICLOUD_SECRET_KEY: ${{ secrets.ALICLOUD_SECRET_KEY }}
      
      - name: Terraform Apply
        run: terraform apply -auto-approve tfplan
        working-directory: ${{ env.TF_WORKING_DIR }}
        env:
          ALICLOUD_ACCESS_KEY: ${{ secrets.ALICLOUD_ACCESS_KEY }}
          ALICLOUD_SECRET_KEY: ${{ secrets.ALICLOUD_SECRET_KEY }}
```

### 8.2 Makefile封装

```makefile
# Makefile
.PHONY: init plan apply destroy fmt validate clean

ENV ?= dev
WORK_DIR = environments/$(ENV)

init:
	cd $(WORK_DIR) && terraform init

plan:
	cd $(WORK_DIR) && terraform plan

apply:
	cd $(WORK_DIR) && terraform apply -auto-approve

destroy:
	cd $(WORK_DIR) && terraform destroy -auto-approve

fmt:
	terraform fmt -recursive

validate:
	terraform validate

clean:
	rm -rf $(WORK_DIR)/.terraform $(WORK_DIR)/terraform.tfstate*

# 使用示例
# make init ENV=prod
# make plan ENV=prod
# make apply ENV=prod
```

## 九、安全最佳实践

### 9.1 敏感信息管理

```hcl
# 使用变量避免硬编码
variable "db_password" {
  description = "数据库密码"
  type        = string
  sensitive   = true  # 输出时隐藏
}

# 从密钥管理器读取
data "alicloud_kms_ciphertext" "db_password" {
  plaintext = var.db_password
}

resource "alicloud_db_instance" "default" {
  # ...
  db_password = data.alicloud_kms_ciphertext.db_password.ciphertext_blob
}
```

### 9.2 策略即代码（Sentinel / OPA）

```rego
# policy/restrict_instance_type.rego — OPA策略
package terraform

import future.keywords.if

# 禁止使用过时实例类型
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "alicloud_instance"
  
  old_types := {"ecs.t5", "ecs.sn1", "ecs.n1"}
  instance_type := resource.change.after.instance_type
  
  startswith(instance_type, old_types[_])
  
  msg := sprintf("禁止使用过时实例类型: %v (资源: %v)", [instance_type, resource.address])
}

# 强制生产环境标签
deny[msg] {
  resource := input.resource_changes[_]
  resource.mode == "managed"
  
  resource.change.after.tags
  tags := resource.change.after.tags
  not tags["ManagedBy"] == "Terraform"
  
  msg := sprintf("资源必须包含ManagedBy标签: %v", [resource.address])
}
```

## 十、生产实践

| 实践 | 说明 | 重要性 |
|-----|------|--------|
| 远程状态存储 | 使用OSS/S3存储状态文件 | ⭐⭐⭐⭐⭐ |
| 状态锁 | 防止并发操作 | ⭐⭐⭐⭐⭐ |
| 模块化 | 将基础设施模块化复用 | ⭐⭐⭐⭐⭐ |
| 版本约束 | 锁定Provider版本 | ⭐⭐⭐⭐ |
| 环境隔离 | 不同环境使用不同状态文件 | ⭐⭐⭐⭐⭐ |
| CI/CD集成 | 自动化Plan/Apply流程 | ⭐⭐⭐⭐ |
| 敏感信息管理 | 使用KMS/Vault管理密钥 | ⭐⭐⭐⭐⭐ |
| 策略检查 | 使用OPA/Sentinel | ⭐⭐⭐⭐ |
| 成本分析 | 使用infracost估算成本 | ⭐⭐⭐ |
| 测试验证 | 使用Terratest进行集成测试 | ⭐⭐⭐⭐ |

## 十一、总结

Terraform作为基础设施即代码的核心工具，其价值体现在：

1. **声明式配置**：用代码描述基础设施目标状态
2. **资源编排**：自动处理资源依赖和创建顺序
3. **状态管理**：精确跟踪所有资源配置
4. **模块复用**：通过Module构建标准化的基础设施组件
5. **多云支持**：一套工作流管理多个云平台

推荐的生产方案：模块化设计 + 远程状态存储 + CI/CD自动化 + 策略检查 + 密钥管理。Terraform不仅是基础设施管理工具，更是云原生时代团队协作和DevOps实践的核心基础设施。
