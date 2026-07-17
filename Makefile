links:
	@echo "Prometheus: http://localhost:9090"
	@echo "Grafana: http://localhost:3000"

build-api:
	#docker build -t mlops-coherent_text-api -f ./src/api/v1/Dockerfile .
	docker build -t mlops-coherent_text-api -f ./src/api/v2/Dockerfile .

run-api:
	#docker run --name coherent_text-api -p 8000:8000 mlops-coherent_text-api ## Pour afficher les logs
	docker run --rm -d --name coherent_text-api -p 8000:8000 mlops-coherent_text-api

stop-api:
	docker stop coherent_text-api

start-project:
	docker compose -p mlops up -d --build
	#docker compose -p mlops up --build ## Pour afficher les logs des services

stop-project:
	docker compose -p mlops down

rerun: stop-project start-project links

test-api:
	curl -X POST "https://localhost/predict" \
     -H "Content-Type: application/json" \
     -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
	 --user admin:admin \
     --cacert ./deployments/nginx/certs/nginx.crt;

test-api-basic:
	curl -X POST "http://localhost:8000/predict" \
	 -H "Content-Type: application/json" \
	 -d '{"sentence": "Oh yeah, that was soooo cool!"}'

 test-api-reverse_proxy:
	curl -X POST "http://localhost:8080/predict" \
	 -H "Content-Type: application/json" \
	 -d '{"sentence": "Oh yeah, that was soooo cool!"}'

 test-api-https:
	curl -X POST "https://localhost/predict" \
	 -H "Content-Type: application/json" \
	 -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
  	 --cacert ./deployments/nginx/certs/nginx.crt;

 test-api-rate_limiting:
 # Le & envoie chaque curl en tâche de fond sans attendre sa réponse avant de lancer le suivant.
 # wait attend que toutes les tâches soient terminées avant de continuer.
	for i in $$(seq 1 20); do \
		curl -s -o /dev/null -w "%{http_code}\n" \
		-X POST "https://localhost/predict" \
		-H "Content-Type: application/json" \
		-d '{"sentence": "Oh yeah, that was soooo cool!"}' \
		--user "admin:admin" \
		--cacert ./deployments/nginx/certs/nginx.crt & \
	done; \
	wait

test-api_A/B_testing:
	@echo "Router sur api-v1 (pas de "prediction_proba_dict" dans la réponse)\n"
	curl -k -u admin:admin -X POST "https://localhost/predict" \
	  -H "Content-Type: application/json" \
	  -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
	  --cacert ./deployments/nginx/certs/nginx.crt;
	@echo "\n"
	@echo "Router sur api-v2 (avec "prediction_proba_dict" en plus)\n"
	curl -k -u admin:admin -X POST "https://localhost/predict" \
	  -H "Content-Type: application/json" \
	  -H "X-Experiment-Group: debug" \
	  -d '{"sentence": "Oh yeah, that was soooo cool!"}' \
  	  --cacert ./deployments/nginx/certs/nginx.crt;

test:
	 @bash tests/run_tests.sh



