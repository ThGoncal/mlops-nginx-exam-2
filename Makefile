run-project:
	# run project
	@echo "Grafana UI: http://localhost:3000"

build-api:
	#docker build -t mlops-coherent_text-api -f ./src/api/v1/Dockerfile .
	docker build -t mlops-coherent_text-api -f ./src/api/v2/Dockerfile .

run-api:
	docker run --name coherent_text-api -p 8000:8000 mlops-coherent_text-api
	#docker run --rm -d --name coherent_text-api -p 8000:8000 mlops-coherent_text-api

stop-api:
	docker stop coherent_text-api

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
