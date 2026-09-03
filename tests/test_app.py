from app import main


def test_liveness_is_independent_of_database():
    client = main.app.test_client()
    response = client.get("/health/live")

    assert response.status_code == 200
    assert response.get_json()["status"] == "alive"


def test_readiness_when_database_is_available(monkeypatch):
    monkeypatch.setattr(main, "check_database", lambda: None)
    client = main.app.test_client()

    response = client.get("/health/ready")

    assert response.status_code == 200
    assert response.get_json()["database"] == "reachable"


def test_readiness_when_database_is_unavailable(monkeypatch):
    def database_failure():
        raise OSError("simulated database DNS failure")

    monkeypatch.setattr(main, "check_database", database_failure)
    client = main.app.test_client()

    response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.get_json()["status"] == "not ready"


def test_visits_uses_database(monkeypatch):
    monkeypatch.setattr(main, "increment_visits", lambda: 42)
    client = main.app.test_client()

    response = client.get("/visits")

    assert response.status_code == 200
    assert response.get_json() == {"database": "postgresql", "visits": 42}

