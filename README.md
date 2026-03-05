# Year 4 Project Deployment Repository

This repository contains Kubernetes manifests for deploying the Year 4 Project microservices architecture in production environments.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Services](#services)
4. [Kubernetes Structure](#kubernetes-structure)
5. [Configuration Details](#configuration-details)
6. [Deployment Instructions](#deployment-instructions)

## Overview

This deployment repo defines the complete infrastructure setup for a microservices-based application using Kubernetes. It includes multiple backend services, database access layers, a frontend application, and an nginx gateway for traffic routing.

**Key Features:**
- Multi-tier microservices architecture
- Load balancing and reverse proxy via nginx
- Health checks and readiness probes
- Resource limits and requests
- Security headers and rate limiting
- JSON logging for monitoring

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                       │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │         Nginx Gateway (3 replicas)                     │  │
│  │  - Reverse proxy for all requests                      │  │
│  │  - Rate limiting and security headers                  │  │
│  │  - Routes to appropriate backend services              │  │
│  └────────────────────────────────────────────────────────┘  │
│                          │                                    │
│         ┌────────────────┼────────────────┬──────────────┬───┴─────────┐
│         │                │                │              │              │
│    ┌────▼──┐    ┌───────▼─┐    ┌────────▼──┐   ┌──────▼───┐   ┌─────▼──┐
│    │Frontend│    │  Auth   │    │   User    │   │   Job    │   │Customer │
│    │Service │    │ Service │    │ Service   │   │ Service  │   │ Service │
│    │(8000)  │    │  (8005) │    │   (8004)  │   │  (8006)  │   │ (8007)  │
│    └────┬──┘    └───────┬─┘    └────────┬──┘   └──────┬───┘   └─────┬──┘
│         │                │                │              │              │
│    ┌────▼──────────┐────▼──────────┬────▼──────────┴───▼──────────┐   │
│    │                              Database Access Services         │   │
│    └───────────────────────────────────────────────────────────┬──┘   │
│         │              │              │              │              │   │
│    ┌────▼────┐   ┌─────▼─────┐  ┌────▼─────┐  ┌─────▼──────┐     │   │
│    │  User   │   │   Job     │  │ Customer │  │    Admin   │     │   │
│    │   DB    │   │    DB     │  │    DB    │  │     DB     │     │   │
│    │ Access  │   │  Access   │  │ Access   │  │  Access    │     │   │
│    │(8001)   │   │   (8003)  │  │  (8002)  │  │   (8009)   │     │   │
│    └────▬────┘   └─────┬─────┘  └────┬─────┘  └─────┬──────┘     │   │
│         │              │              │              │            │   │
└─────────┼──────────────┼──────────────┼──────────────┼────────────┼───┘
          │              │              │              │            │
```

## Services

### Frontend Service
- **Container Port:** 8000
- **Replicas:** 2
- **Purpose:** Web application frontend serving user interface
- **Endpoint:** Exposed via nginx gateway at root `/`

### Auth Service
- **Container Port:** 8005
- **Replicas:** 2
- **Purpose:** Authentication and authorization service
- **Endpoints:** 
  - `POST /api/v1/auth/login` - User login
  - `POST /api/v1/auth/logout` - User logout
  - `GET /api/v1/auth/verify` - Token verification
- **Rate Limit:** 5 requests/second (strict auth limiting)
- **Database:** Uses user-db-access-service

### User Business Logic Service
- **Container Port:** 8004
- **Replicas:** 2
- **Purpose:** Handles user-related business logic and operations
- **Endpoints:** REST API for user management
- **Database:** Uses user-db-access-service

### User Database Access Service
- **Container Port:** 8001
- **Replicas:** 2
- **Purpose:** Database abstraction layer for user data
- **Endpoints:** Provides data persistence for user service

### Job Business Logic Service
- **Container Port:** 8006
- **Replicas:** 2
- **Purpose:** Handles job-related operations and scheduling
- **Endpoints:** REST API for job management and tracking
- **Database:** Uses job-db-access-service

### Job Database Access Service
- **Container Port:** 8003
- **Replicas:** 2
- **Purpose:** Database abstraction layer for job data
- **Endpoints:** Provides data persistence for job service

### Customer Business Logic Service
- **Container Port:** 8007
- **Replicas:** 2
- **Purpose:** Manages customer information and interactions
- **Endpoints:** REST API for customer data management
- **Database:** Uses customer-db-access-service

### Customer Database Access Service
- **Container Port:** 8002
- **Replicas:** 2
- **Purpose:** Database abstraction layer for customer data
- **Endpoints:** Provides data persistence for customer service

### Admin Business Logic Service
- **Container Port:** 8008
- **Replicas:** 2
- **Purpose:** Administrative functions and system management
- **Endpoints:** Restricted admin API endpoints
- **Rate Limit:** 10 requests/second (strict admin limiting)
- **Database:** Uses admin-db-access-service

### Admin Database Access Service
- **Container Port:** 8009
- **Replicas:** 2
- **Purpose:** Database abstraction layer for admin data
- **Endpoints:** Provides data persistence for admin service

### Nginx Gateway
- **Container Port:** 80
- **Replicas:** 3
- **Purpose:** Main entry point for all traffic
- **Features:**
  - Reverse proxy to all backend services
  - Request rate limiting per endpoint
  - Security headers (HSTS, X-Frame-Options, CSP, etc.)
  - JSON structured logging
  - Connection pooling and keepalive
  - Gzip compression
  - Health check endpoint at `/health`

## Kubernetes Structure

All Kubernetes manifests are located in `kubernetes/base/`:

### Deployment Manifests
Each service has a corresponding deployment file defining:
- **Replicas:** Number of pod instances (typically 2-3)
- **Container Image:** Docker image from `bencev04/4th-year-proj-tadgh-bence:*-latest`
- **Resource Requests:** Min CPU (250m) and Memory (256Mi)
- **Resource Limits:** Max CPU (500m) and Memory (512Mi)
- **Health Checks:**
  - **Liveness Probe:** Checks service health at `/health` endpoint (30s initial delay)
  - **Readiness Probe:** Checks service readiness (5s initial delay)
- **Environment Variables:**
  - `ENVIRONMENT: production`
  - `LOG_LEVEL: INFO`

### Service Manifests
Each deployment has a corresponding service file defining:
- **Type:** ClusterIP (internal service discovery)
- **Port Mapping:** From 80 (service port) to container port
- **Service Discovery:** Internal DNS via service names

### Configuration Files

**nginx-configmap.yaml:**
Contains the complete nginx configuration including:
- Upstream server definitions for all backend services
- Request routing rules with path-based routing
- Rate limiting zones for different endpoints:
  - Auth endpoints: 5 requests/second
  - General API: 30 requests/second
  - Admin: 10 requests/second
- Security headers for XSS, clickjacking, and CORS protection
- Proxy buffering and timeouts
- Connection pooling settings

**ingress-gateway.yml:**
Kubernetes Ingress resource routing external traffic:
- Maps `localhost` host to nginx-gateway service
- Configures path routing (currently root path `/`)

## Configuration Details

### Resource Allocation

**Service Pods:**
```
CPU Request: 250m (0.25 cores)
CPU Limit: 500m (0.5 cores)
Memory Request: 256Mi
Memory Limit: 512Mi
```

**Nginx Gateway:**
- Higher configuration for increased load handling

### Health Checks

**Liveness Probe:**
- Restarts unhealthy containers
- Initial delay: 30 seconds
- Check interval: 10 seconds
- Endpoint: `/health`

**Readiness Probe:**
- Removes containers from load balancer when not ready
- Initial delay: 5 seconds
- Check interval: 5 seconds
- Endpoints: `/health` or `/ready`

### Rate Limiting

Nginx implements multiple rate limit zones:

**Authentication Endpoints:**
- Zone: `auth_limit`
- Rate: 5 requests/second
- Burst: 10 requests allowed

**General API Endpoints:**
- Zone: `api_general`
- Rate: 30 requests/second
- Burst: 20 requests allowed

**Admin Endpoints:**
- Zone: `api_general`
- Rate: 30 requests/second (shared)
- Burst: 10 requests allowed

### Security Features

**HTTP Headers:**
- `Strict-Transport-Security`: HTTPS enforcement
- `X-Frame-Options`: Clickjacking protection
- `X-Content-Type-Options`: MIME type sniffing protection
- `X-XSS-Protection`: XSS filter activation
- `Referrer-Policy`: Referrer information control
- `Permissions-Policy`: Feature/API allowance control
- `X-Robots-Tag`: Search engine directives

**Container Security:**
- Non-root user execution (nginx runs as user 101)
- Dropped capabilities (only NET_BIND_SERVICE retained)
- Read-only root filesystem where applicable

**Connection Management:**
- Session affinity (ClientIP) on nginx gateway (3-hour timeout)
- Keepalive connections (10-16 connections per upstream)
- Connection pooling

### Logging

**Format:** JSON structured logging
**Fields:**
- Timestamp (ISO 8601)
- Client IP and forwarded IPs
- HTTP method and path
- Response status code
- Response body size
- Request processing time
- Upstream response time
- User agent
- Request ID (X-Request-ID)

## Deployment Instructions

### Prerequisites
- Kubernetes cluster (1.20+)
- `kubectl` configured to access the cluster
- Docker images built and pushed to registry
- Persistent volume provisioning (if using databases)

### Deploy All Services

```bash
# Deploy everything from base directory
kubectl apply -f kubernetes/base/

# Verify deployments
kubectl get deployments
kubectl get services
kubectl get pods
```

### Check Service Status

```bash
# View pod logs
kubectl logs -f deployment/auth-service

# Check service endpoints
kubectl get endpoints

# Describe service issues
kubectl describe pod <pod-name>
```

### Port Forwarding for Local Testing

```bash
# Access nginx gateway locally
kubectl port-forward svc/nginx-gateway 8080:80

# Access individual services
kubectl port-forward svc/auth-service 8005:80
```

### Scaling Services

```bash
# Scale a deployment
kubectl scale deployment/job-bl-service --replicas=3

# View autoscaling status
kubectl get hpa
```

## Networking

### Internal Service Discovery
Services communicate using Kubernetes DNS:
- `auth-service:80` - Auth service
- `user-bl-service:80` - User business logic
- `job-bl-service:80` - Job business logic
- etc.

### Port Mapping Summary
| Service | Deployment Port | Service Port | External |
|---------|-----------------|--------------|----------|
| Frontend | 8000 | 80 | Via nginx |
| Auth | 8005 | 80 | Via nginx |
| User BL | 8004 | 80 | Via nginx |
| User DB | 8001 | 80 | Internal |
| Job BL | 8006 | 80 | Via nginx |
| Job DB | 8003 | 80 | Internal |
| Customer BL | 8007 | 80 | Via nginx |
| Customer DB | 8002 | 80 | Internal |
| Admin BL | 8008 | 80 | Via nginx |
| Admin DB | 8009 | 80 | Internal |
| Nginx | 80 | 80 | External |

## Maintenance

### Updating Service Images
```bash
# Update image for a deployment
kubectl set image deployment/auth-service auth-service=bencev04/4th-year-proj-tadgh-bence:auth-service-v2.0
```

### Rolling Updates
Deployments automatically perform rolling updates:
- New pods start with new image
- Old pods terminate after new ones are ready
- No service downtime

### Monitoring
Monitor service health via:
- `kubectl get pods` - Pod status
- Liveness/readiness probe results
- Application logs via `kubectl logs`
- Prometheus metrics (if configured)

## Troubleshooting

**Service unreachable:**
- Check pod status: `kubectl get pods`
- Verify service exists: `kubectl get svc <service-name>`
- Check endpoint mapping: `kubectl get endpoints <service-name>`
- Review probes: `kubectl describe pod <pod-name>`

**High memory usage:**
- Increase memory limit in deployment manifest
- Check for memory leaks in application logs
- Monitor with `kubectl top pods`

**Request timeouts:**
- Check nginx proxy timeouts (proxy_read_timeout)
- Verify backend service health probes
- Scale up replicas if overloaded

**Port conflicts:**
- Ensure no other services using same ports
- Verify port mappings match between deployment and service

---

For questions or issues, refer to individual service documentation or deployment logs.
