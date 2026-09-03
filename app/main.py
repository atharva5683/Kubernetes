import json
import logging
import os
import socket
import time

import pymongo
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
    "Whether the backend can currently query MongoDB",
)


def _mongo_client():
    host = os.getenv("DB_HOST", "mongodb")
    port = int(os.getenv("DB_PORT", "27017"))
    password = os.environ["MONGO_PASSWORD"]
    user = os.getenv("DB_USER", "challenge")
    uri = f"mongodb://{user}:{password}@{host}:{port}/"
    return pymongo.MongoClient(uri, serverSelectionTimeoutMS=2000)


def check_database() -> None:
    client = _mongo_client()
    client.admin.command("ping")
    client.close()


def increment_visits() -> int:
    client = _mongo_client()
    db = client[os.getenv("DB_NAME", "challenge")]
    result = db.visits.find_one_and_update(
        {"_id": "counter"},
        {"$inc": {"count": 1}},
        upsert=True,
        return_document=pymongo.ReturnDocument.AFTER,
    )
    client.close()
    return int(result["count"])


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
        return jsonify({"visits": count, "database": "mongodb"})
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
            os.getenv("DB_HOST", "mongodb"),
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
