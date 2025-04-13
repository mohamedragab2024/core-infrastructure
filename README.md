# core-infrastructure

<img width="1907" alt="Screenshot 2025-04-12 at 12 34 45" src="https://github.com/user-attachments/assets/2e261e37-2ea5-43ce-90b2-f4d4f4a6ab3c" />

## Folders 

- clusters/ terraform
- argocd values.yaml
- apps  helm chart to install core apps argocd applications
    - nginx
    - cert-manager
    - clusterIssuer
  
## Tools 
 - terraform
 - helm
 - kubectl
 - argocd cli

## GHA workflow
 - Terraform initiate k8s cluster on Civo cloud provider
 - Get kubeconfig content as a result from terraform
 - Deploy argocd using helm
 - Deploy app of apps using kubectl
 - Check nginx readniess and grep Loadbalancer IP
 - Use name.com APIs and update dns records
 - cron workflow to destory the k8s cluster using terraform destory every Sunday (optional) 
