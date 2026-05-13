# Makefile for bjs-todo-api
#
# Required environment variables for `push` and `deploy`:
#   ECR_REPO_URL     e.g. 123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn/bjs-todo-api
#   AWS_REGION       defaults to cn-north-1
#   AWS_PROFILE      defaults to ychchen-bjs1
#   K8S_CONTEXT      defaults to bjs1
#   IMAGE_TAG        defaults to v1.2.3
#
# Targets:
#   make build       # docker build (linux/amd64)
#   make push        # docker push to ECR (does ECR login)
#   make deploy      # kubectl apply k8s manifests with image substituted
#   make seed        # populate ~10k users via the live API
#   make local-run   # docker compose up (postgres + api)

SHELL := /usr/bin/env bash

IMAGE_NAME    ?= bjs-todo-api
IMAGE_TAG     ?= v1.2.3
ECR_REPO_URL  ?=
AWS_REGION    ?= cn-north-1
AWS_PROFILE   ?= ychchen-bjs1
K8S_CONTEXT   ?= bjs1
NAMESPACE     ?= bjs-web
PLATFORM      ?= linux/amd64

LOCAL_IMAGE   := $(IMAGE_NAME):$(IMAGE_TAG)
REMOTE_IMAGE  := $(ECR_REPO_URL):$(IMAGE_TAG)

.PHONY: help
help:
	@echo "Targets: build push deploy seed local-run lint clean"
	@echo "Vars: IMAGE_TAG=$(IMAGE_TAG) AWS_REGION=$(AWS_REGION) AWS_PROFILE=$(AWS_PROFILE)"

.PHONY: build
build:
	docker build --platform $(PLATFORM) -t $(LOCAL_IMAGE) .
	@if [ -n "$(ECR_REPO_URL)" ]; then \
		docker tag $(LOCAL_IMAGE) $(REMOTE_IMAGE); \
		echo "tagged $(REMOTE_IMAGE)"; \
	fi

.PHONY: push
push:
	@if [ -z "$(ECR_REPO_URL)" ]; then echo "ECR_REPO_URL is required"; exit 1; fi
	aws ecr get-login-password --profile $(AWS_PROFILE) --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin $$(echo $(ECR_REPO_URL) | cut -d/ -f1)
	docker push $(REMOTE_IMAGE)

.PHONY: deploy
deploy:
	@if [ -z "$(ECR_REPO_URL)" ]; then echo "ECR_REPO_URL is required"; exit 1; fi
	kubectl --context $(K8S_CONTEXT) apply -f k8s/namespace.yaml
	@echo "Reminder: create the secret first if it doesn't exist:"
	@echo "  kubectl --context $(K8S_CONTEXT) -n $(NAMESPACE) create secret generic bjs-todo-db-secret ..."
	export ECR_REPO_URL=$(ECR_REPO_URL); \
	envsubst '$$ECR_REPO_URL' < k8s/deployment.yaml \
		| kubectl --context $(K8S_CONTEXT) apply -f -
	kubectl --context $(K8S_CONTEXT) apply -f k8s/service.yaml
	kubectl --context $(K8S_CONTEXT) apply -f k8s/ingress.yaml
	kubectl --context $(K8S_CONTEXT) -n $(NAMESPACE) rollout status deploy/todo-api --timeout=300s

.PHONY: seed
seed:
	BASE_URL=$${BASE_URL:-http://localhost:8000} TOTAL=$${TOTAL:-10000} python seed.py

.PHONY: local-run
local-run:
	docker compose up --build

.PHONY: clean
clean:
	docker compose down -v || true
	docker rmi $(LOCAL_IMAGE) || true
