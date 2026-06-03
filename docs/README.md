# 文档索引

本项目文档按用途分类。根目录的 [README.md](../README.md) 是项目总览与快速开始。

## 🔐 部署（当前推荐：ECS Fargate + Roles Anywhere）

| 文档 | 说明 |
|---|---|
| [deploy/DEPLOY-ROLES-ANYWHERE.md](./deploy/DEPLOY-ROLES-ANYWHERE.md) | IAM Roles Anywhere 零密钥部署指南 |
| [deploy/DEPLOY-RA-RECORD.md](./deploy/DEPLOY-RA-RECORD.md) | 真实部署日志（含精确命令，可复制执行） |
| [deploy/REBUILD.md](./deploy/REBUILD.md) | 销毁现有资源 + 按最新代码重建的 runbook |

## ⚠️ 旧版 EKS 方案（保留供参考，新部署请用 ECS）

| 文档 | 说明 |
|---|---|
| [legacy-eks/SETUP.md](./legacy-eks/SETUP.md) | EKS 方案从零到运行的完整配置指南 |
| [legacy-eks/MULTI-ACCOUNT.md](./legacy-eks/MULTI-ACCOUNT.md) | EKS 多账号扩展运维（Helm chart + ESO） |

## 📖 背景阅读

| 文档 | 说明 |
|---|---|
| [blog/BLOG.md](./blog/BLOG.md) | 7 层故障面的故事版踩坑排查 |
| [aws-devops-agent-value-for-ops.md](./aws-devops-agent-value-for-ops.md) | AWS DevOps Agent 对运维团队的价值 |
