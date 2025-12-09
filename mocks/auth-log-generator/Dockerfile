FROM python:3.11-slim
WORKDIR /app
COPY generate_auth_logs.py .
RUN chmod +x generate_auth_logs.py
CMD ["python", "-u", "generate_auth_logs.py"]
