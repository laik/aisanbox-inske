FROM python:3.12-alpine
RUN pip install --no-cache-dir "anthropic>=0.69" "opentelemetry-sdk>=1.34" "opentelemetry-exporter-otlp-proto-http>=1.34"
WORKDIR /agent
COPY agent.py /usr/local/lib/aisanbox/agent.py
USER 10001
