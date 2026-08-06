FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl sqlite3 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV DB_PATH=/data/diagnostics.db
ENV BACKEND_PORT=5001
VOLUME ["/data"]
EXPOSE 5001
CMD ["python3", "-u", "app.py"]
