FROM python:3.11-slim
WORKDIR /app
COPY generate_metrics.py .
RUN pip install prometheus-client requests
CMD ["python", "generate_metrics.py"]