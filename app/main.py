import json
import logging
import os
import socket
import time

import psycopg
from flask import Flask, Response, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps(
            {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "level": record.levelname,
                "message": record.getMessage(),
                "logger": record.name,
            }
        )


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logger = logging.getLogger("challenge-api")
logger.handlers.clear()
logger.addHandler(handler)
logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))
logger.propagate = False

app = Flask(__name__)

HTTP_REQUESTS = Counter(
    "challenge_http_requests_total",
    "Total HTTP responses from the backend",
    ["method", "endpoint", "status"],
)
DB_READY = Gauge(
    "challenge_database_ready",
    "Whether the backend can currently query PostgreSQL",
)


def database_connection():
    return psycopg.connect(
        host=os.getenv("DB_HOST", "postgres"),
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.getenv("DB_NAME", "challenge"),
        user=os.getenv("DB_USER", "challenge"),
        password=os.environ["DB_PASSWORD"],
        connect_timeout=2,
    )


def check_database() -> None:
    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            cursor.fetchone()


def increment_visits() -> int:
    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                CREATE TABLE IF NOT EXISTS visits (
                    id INTEGER PRIMARY KEY,
                    count BIGINT NOT NULL
                )
                """
            )
            cursor.execute(
                """
                INSERT INTO visits (id, count) VALUES (1, 1)
                ON CONFLICT (id)
                DO UPDATE SET count = visits.count + 1
                RETURNING count
                """
            )
            row = cursor.fetchone()
            return int(row[0])


@app.after_request
def record_request(response):
    try:
        endpoint = request.endpoint or "unknown"
        HTTP_REQUESTS.labels(request.method, endpoint, str(response.status_code)).inc()
    except Exception:
        logger.exception("failed_to_record_request_metric")
    return response


@app.get("/")
def index():
    return jsonify(
        {
            "message": "DevOps challenge API is running",
            "hostname": socket.gethostname(),
            "version": os.getenv("APP_VERSION", "local"),
            "database_demo": "/visits",
            "health": {"live": "/health/live", "ready": "/health/ready"},
            "metrics": "/metrics",
        }
    )


@app.get("/visits")
def visits():
    try:
        count = increment_visits()
        logger.info("visit_recorded count=%s", count)
        return jsonify({"visits": count, "database": "postgresql"})
    except Exception as exc:
        logger.error("visit_failed error_type=%s error=%s", type(exc).__name__, exc)
        return jsonify({"error": "database unavailable"}), 503


@app.get("/health/live")
def liveness():
    return jsonify({"status": "alive"})


@app.get("/health/ready")
def readiness():
    try:
        check_database()
        DB_READY.set(1)
        return jsonify({"status": "ready", "database": "reachable"})
    except Exception as exc:
        DB_READY.set(0)
        logger.warning(
            "readiness_failed db_host=%s error_type=%s error=%s",
            os.getenv("DB_HOST", "postgres"),
            type(exc).__name__,
            exc,
        )
        return jsonify({"status": "not ready", "database": "unreachable"}), 503


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.errorhandler(404)
def not_found(_error):
    return jsonify({"error": "not found"}), 404
