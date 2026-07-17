# Examen Nginx — API de reconnaissance de sentiments (`mlops-nginx-exam`)

Ce document présente l'architecture mise en place, les choix techniques
retenus, et la façon de valider chaque exigence de l'énoncé.

## Sommaire

- [Vue d'ensemble](#vue-densemble)
- [Architecture](#architecture)
- [Mise en route](#mise-en-route)
- [Détail des fonctionnalités](#détail-des-fonctionnalités)
  1. [Reverse Proxy](#1--reverse-proxy)
  2. [Load Balancing](#2--load-balancing)
  3. [Sécurité HTTPS](#3--sécurité-https)
  4. [Contrôle d'accès](#4--contrôle-daccès)
  5. [Rate Limiting](#5--rate-limiting)
  6. [A/B Testing](#6--ab-testing)
  7. [Monitoring (bonus)](#7--monitoring-bonus)
- [Commandes Makefile](#commandes-makefile)
- [Validation automatisée](#validation-automatisée)
- [Notes pour l'examinateur](#notes-pour-lexaminateur)

## Vue d'ensemble

L'API prédit le sentiment d'une phrase donnée (`anger`, `happiness`,
`sadness`, etc.) à partir d'un modèle `model.joblib` pré-entraîné. Elle est
déclinée en deux versions :

- **`api-v1`** : version standard, retourne uniquement la classe prédite.
- **`api-v2`** : version "debug", retourne en plus le détail des
  probabilités par classe (`prediction_proba_dict`).

L'ensemble est placé derrière un reverse proxy Nginx qui centralise le
routage, la sécurité et l'observabilité.

## Architecture

```
                              Utilisateur
                                   │
                    HTTP :8080 (→ 301)  │  HTTPS :443
                                   ▼
                    ┌────────────────────────────────┐
                    │        nginx_revproxy           │
                    │  • Redirection HTTP → HTTPS      │
                    │  • Terminaison SSL/TLS            │
                    │  • Auth basique (.htpasswd)       │
                    │  • Rate limiting (10 r/s)         │
                    │  • Routage A/B (map sur en-tête)  │
                    │  • /nginx_status (stub_status)    │
                    └───────┬──────────────┬───────────┘
                            │              │
              en-tête absent│              │en-tête:
              ou ≠ "debug"  │              │X-Experiment-Group: debug
                            ▼              ▼
              ┌──────────────────┐   ┌──────────────────┐
              │  upstream v1      │   │  upstream v2      │
              │  (3 réplicas,     │   │  (1 instance)      │
              │  round robin)     │   │                    │
              │ ┌────┐┌────┐┌────┐│   │     ┌────┐         │
              │ │ #1 ││ #2 ││ #3 ││   │     │ #1 │         │
              │ └────┘└────┘└────┘│   │     └────┘         │
              └──────────────────┘   └──────────────────┘
                            │
                            │ scrape /nginx_status (HTTPS)
                            ▼
                    ┌──────────────────┐
                    │  nginx_exporter   │
                    │     :9113          │
                    └─────────┬─────────┘
                              ▼
                    ┌──────────────────┐
                    │    Prometheus      │
                    │      :9090          │
                    └─────────┬─────────┘
                              ▼
                    ┌──────────────────┐
                    │      Grafana        │
                    │      :3000           │
                    │ (dashboard NGINX)   │
                    └──────────────────┘
```

L'API n'est **jamais** exposée directement à l'extérieur : les services
`coherent_text-api-v1` et `coherent_text-api-v2` utilisent `expose` (visible
uniquement sur le réseau Docker interne), tandis que seul `nginx` publie des
ports vers l'hôte (`ports`).

## Mise en route

### 1. Générer le certificat SSL auto-signé

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout deployments/nginx/certs/nginx.key \
    -out deployments/nginx/certs/nginx.crt \
    -subj "/CN=localhost"
```

### 2. Générer le fichier d'authentification basique

```bash
sudo apt install apache2-utils -y
htpasswd -c deployments/nginx/.htpasswd admin
```

> Le fichier `.htpasswd` fourni dans l'énoncé peut déjà contenir des
> identifiants ; adapter en conséquence les commandes de test si besoin.

### 3. Lancer la stack complète

```bash
make start-project
# équivalent à : docker compose -p mlops up --build
```

### 4. Arrêter la stack

```bash
make stop-project
```

## Détail des fonctionnalités

### 1 — Reverse Proxy

Nginx est le point d'entrée unique. Toute requête externe transite par lui ;
aucune API n'est jamais contactée directement depuis l'extérieur.

```nginx
location /predict {
    proxy_pass http://$backend_pool;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Les en-têtes `X-Real-IP`, `X-Forwarded-For` et `X-Forwarded-Proto` sont
transmis aux backends afin qu'ils connaissent l'adresse IP réelle du client
et le protocole d'origine, malgré la présence du proxy.

### 2 — Load Balancing

`api-v1` est déclarée avec 3 réplicas dans `docker-compose.yml` :

```yaml
coherent_text-api-v1:
  deploy:
    replicas: 3
```

Nginx répartit le trafic entre ces instances via un bloc `upstream`,
selon l'algorithme **Round Robin** (comportement par défaut, chaque
instance reçoit son tour) :

```nginx
upstream coherent_text-apis-v1 {
    server coherent_text-api-v1:8000;
}
```

La résolution DNS Docker fait automatiquement le lien entre le nom du
service et ses 3 instances sous-jacentes.

### 3 — Sécurité HTTPS

Un premier bloc `server` écoute en HTTP simple (port 80) et redirige
systématiquement vers HTTPS :

```nginx
server {
    listen 80;
    return 301 https://$host$request_uri;
}
```

Un second bloc gère la terminaison TLS avec un certificat auto-signé :

```nginx
server {
    listen 443 ssl;
    ssl_certificate     /etc/nginx/certs/nginx.crt;
    ssl_certificate_key /etc/nginx/certs/nginx.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
}
```

Le déchiffrement s'arrête entièrement au niveau de Nginx ; le trafic vers
les APIs reste en HTTP simple sur le réseau Docker interne, déjà isolé de
l'extérieur.

### 4 — Contrôle d'accès

L'authentification basique protège spécifiquement le endpoint `/predict` :

```nginx
location /predict {
    auth_basic "API Access Protected";
    auth_basic_user_file /etc/nginx/.htpasswd;
    ...
}
```

Toute requête sans identifiants valides reçoit une réponse **401
Unauthorized**.

### 5 — Rate Limiting

Une zone de limitation est déclarée au niveau du bloc `http`, indexée sur
l'adresse IP du client :

```nginx
limit_req_zone $binary_remote_addr zone=apilimit:10m rate=10r/s;
```

Elle est appliquée dans `location /predict` avec une tolérance de rafale :

```nginx
limit_req zone=apilimit burst=5 nodelay;
```

- `rate=10r/s` : 10 requêtes par seconde autorisées par IP.
- `burst=5` : jusqu'à 5 requêtes supplémentaires tolérées en rafale.
- `nodelay` : les requêtes en rafale sont traitées immédiatement (pas de
  mise en file d'attente), au-delà elles reçoivent une erreur **503
  Service Unavailable**.

> ⚠️ Pour observer effectivement des `503`, les requêtes de test doivent
> être envoyées en **parallèle** (ex. avec `&`/`wait` ou `xargs -P`) : des
> requêtes séquentielles (boucle `for` classique) restent naturellement
> sous la limite à cause du temps de négociation TLS entre chaque appel.

### 6 — A/B Testing

Le routage conditionnel repose sur la directive `map`, qui associe la
valeur de l'en-tête HTTP `X-Experiment-Group` à un groupe upstream cible :

```nginx
resolver 127.0.0.11 valid=30s;

map $http_x_experiment_group $backend_pool {
    default   coherent_text-apis-v1;
    debug     coherent_text-apis-v2;
}

upstream coherent_text-apis-v1 {
    server coherent_text-api-v1:8000;
}

upstream coherent_text-apis-v2 {
    server coherent_text-api-v2:8000;
}

location /predict {
    proxy_pass http://$backend_pool;
    ...
}
```

- **`$http_x_experiment_group`** : variable générée automatiquement par
  Nginx à partir de l'en-tête HTTP `X-Experiment-Group`.
- **`default`** : s'applique si l'en-tête est absent ou différent de
  `"debug"` → trafic dirigé vers `api-v1`.
- **`resolver 127.0.0.11`** : requis car `proxy_pass` utilise désormais une
  variable (`$backend_pool`) plutôt qu'un nom fixe ; Nginx doit alors
  résoudre le nom du service à chaque requête, via le DNS interne de
  Docker (`127.0.0.11`).

**Test manuel :**

```bash
# → api-v1 (pas de détail des probabilités)
curl -k -u admin:admin -X POST "https://localhost/predict" \
    -H "Content-Type: application/json" \
    -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
    --cacert ./deployments/nginx/certs/nginx.crt

# → api-v2 (avec prediction_proba_dict)
curl -k -u admin:admin -X POST "https://localhost/predict" \
    -H "Content-Type: application/json" \
    -H "X-Experiment-Group: debug" \
    -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
    --cacert ./deployments/nginx/certs/nginx.crt
```

### 7 — Monitoring (bonus)

La chaîne d'observabilité s'appuie sur quatre composants :

1. **`stub_status`** (module Nginx natif) expose des métriques brutes
   (connexions actives, requêtes traitées) sur un endpoint interne,
   restreint par IP :

   ```nginx
   location /nginx_status {
       stub_status on;
       access_log off;
       allow 127.0.0.1;
       allow 172.18.0.0/16;   # sous-réseau Docker — à vérifier avec
                               # `docker network inspect <projet>_default`
       deny all;
   }
   ```

2. **`nginx_exporter`** (`nginx/nginx-prometheus-exporter`) scrape ce
   endpoint et convertit les métriques au format Prometheus, exposées sur
   le port `9113`.

3. **Prometheus** scrape `nginx_exporter` selon la configuration de
   `deployments/prometheus/prometheus.yml`, et expose son interface sur le
   port `9090`.

4. **Grafana** (image `10.4.3`) affiche un dashboard provisionné
   automatiquement au démarrage (volume
   `deployments/grafana/dashboards/`), avec authentification anonyme
   activée pour l'examen (`GF_AUTH_ANONYMOUS_ENABLED=true`).

**Accès :**

| Service | URL |
|---|---|
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 |
| Métriques brutes de l'exporter | http://localhost:9113/metrics |

## Commandes Makefile

| Commande | Effet |
|---|---|
| `make start-project` | Démarre l'ensemble de la stack (`docker compose up --build`) |
| `make stop-project` | Arrête l'ensemble de la stack |
| `make rerun` | Redémarre la stack et affiche les liens utiles |
| `make links` | Affiche les URLs des interfaces (Grafana, etc.) |
| `make test-api` | Test de prédiction basique via HTTPS |
| `make test-api-basic` | Test direct sur le port de l'API (sans proxy) |
| `make test-api-reverse_proxy` | Test via le port HTTP du reverse proxy |
| `make test-api-https` | Test via HTTPS avec vérification du certificat |
| `make test-api-rate_limiting` | Envoi de requêtes concurrentes pour valider le rate limiting |
| `make test` | Exécute la suite de tests automatisés (`tests/run_tests.sh`) |

## Validation automatisée

Le script `tests/run_tests.sh` valide successivement :

1. **Prédiction nominale (v1)** : réponse `200` sur `/predict` sans en-tête
   spécifique.
2. **Routage A/B (v2)** : présence de `prediction_proba_dict` dans la
   réponse lorsque l'en-tête `X-Experiment-Group: debug` est fourni.
3. **Échec d'authentification** : réponse `401` avec des identifiants
   incorrects.
4. **Rate limiting** : envoi de 15 requêtes concurrentes (`&`/`wait`) et
   vérification que le service reste disponible (pas de `502`) malgré la
   présence de `503` intermittents.
5. **Disponibilité de Prometheus** : réponse `200` sur
   `/api/v1/status/runtimeinfo`.
6. **Disponibilité de Grafana** : réponse `200` sur `/api/health`.

```bash
make run_tests
```

## Notes pour l'examinateur

- **Identifiants de test** : `admin` / `admin` (fichier `.htpasswd` fourni
  avec l'énoncé — à adapter si un autre couple identifiant/mot de passe a
  été utilisé).
- **Certificat auto-signé** : les appels `curl` nécessitent soit `-k`
  (ignore la vérification), soit `--cacert
  ./deployments/nginx/certs/nginx.crt` (vérification explicite via
  l'autorité auto-signée).
- **Ports exposés** : `8080` (HTTP, redirige vers HTTPS), `443` (HTTPS),
  `9090` (Prometheus), `3000` (Grafana), `9113` (métriques nginx_exporter).
  Les APIs elles-mêmes (`api-v1`, `api-v2`) ne sont **volontairement pas**
  exposées à l'hôte — seul Nginx y a accès, ce qui est le comportement
  attendu pour un reverse proxy sécurisé.
- **Sous-réseau Docker** : la plage autorisée dans `location
  /nginx_status` (`172.18.0.0/16`) correspond au réseau créé par ce
  projet ; si le sous-réseau réel diffère (vérifiable avec `docker network
  inspect <nom_du_projet>_default`), adapter cette valeur pour que
  `nginx_exporter` puisse scraper les métriques.
