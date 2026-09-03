FROM python:3.12.13-slim-bookworm AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    VIRTUAL_ENV=/opt/venv

WORKDIR /build

RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY requirements.txt ./
RUN pip install --requirement requirements.txt


FROM build AS test

COPY requirements-dev.txt ./
RUN pip install --requirement requirements-dev.txt

COPY app ./app
COPY tests ./tests

CMD ["python", "-m", "pytest", "--quiet"]


FROM python:3.12.13-slim-bookworm AS runtime

ARG APP_VERSION=local

ENV APP_VERSION=${APP_VERSION} \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /opt/app

RUN groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=build /opt/venv /opt/venv
COPY --chown=10001:10001 app ./app

USER 10001:10001
EXPOSE 8080

CMD ["gunicorn", "--bind=0.0.0.0:8080", "--workers=2", "--threads=2", "--timeout=30", "--access-logfile=-", "--error-logfile=-", "app.main:app"]
