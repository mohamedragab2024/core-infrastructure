#!/bin/bash

# Install argocd
helm upgrade --install argocd argo/argo-cd -n argocd -f ./argocd/argocd-values.yaml --create-namespace

# watch argocd-server deployment health

kubectl wait --for=condition=available --timeout=600s deployment/argocd-server -n argocd

# Install argocd app of apps
ktx playground
kubectl apply -f argocd/app-of-apps.yaml
