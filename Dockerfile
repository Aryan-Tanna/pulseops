FROM python:3.13-slim
WORKDIR /opt/pulseops
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home --uid 10001 pulseops && mkdir /data && chown pulseops:pulseops /data
COPY app app
COPY console console
COPY web web
COPY tests tests
USER pulseops
ARG APP_VERSION=1.0.0
ARG COMMIT_SHA=local
ENV APP_VERSION=$APP_VERSION COMMIT_SHA=$COMMIT_SHA
EXPOSE 8000 9001
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "1", "--threads", "8", "--timeout", "30", "app.server:missing_app"]
