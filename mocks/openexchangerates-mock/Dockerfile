FROM python:3.11-slim
WORKDIR /app
COPY mock_server.py .
RUN pip install flask
EXPOSE 8080
CMD ["python", "mock_server.py"]