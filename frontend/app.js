const elements = {
  badge: document.querySelector("#statusBadge"),
  title: document.querySelector("#statusTitle"),
  message: document.querySelector("#statusMessage"),
  hostname: document.querySelector("#hostname"),
  version: document.querySelector("#version"),
  database: document.querySelector("#database"),
  refresh: document.querySelector("#refreshButton"),
  visit: document.querySelector("#visitButton"),
  count: document.querySelector("#visitCount"),
  result: document.querySelector("#visitResult"),
};

async function getJson(path) {
  const response = await fetch(path, { headers: { Accept: "application/json" } });
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
  return body;
}

async function refreshHealth() {
  elements.refresh.disabled = true;
  elements.badge.className = "badge pending";
  elements.badge.textContent = "CHECKING";
  try {
    const [app, ready] = await Promise.all([getJson("/api/"), getJson("/api/health/ready")]);
    elements.badge.className = "badge healthy";
    elements.badge.textContent = "OPERATIONAL";
    elements.title.textContent = "All systems ready";
    elements.message.textContent = "Frontend, backend and database checks succeeded.";
    elements.hostname.textContent = app.hostname;
    elements.version.textContent = app.version.slice(0, 12);
    elements.database.textContent = ready.database;
  } catch (error) {
    elements.badge.className = "badge failed";
    elements.badge.textContent = "DEGRADED";
    elements.title.textContent = "Dependency unavailable";
    elements.message.textContent = error.message;
    elements.database.textContent = "unreachable";
  } finally {
    elements.refresh.disabled = false;
  }
}

async function recordVisit() {
  elements.visit.disabled = true;
  elements.result.textContent = "Writing to PostgreSQL…";
  try {
    const data = await getJson("/api/visits");
    elements.count.textContent = data.visits;
    elements.result.textContent = "Database write and read succeeded.";
  } catch (error) {
    elements.result.textContent = `Request failed: ${error.message}`;
  } finally {
    elements.visit.disabled = false;
  }
}

elements.refresh.addEventListener("click", refreshHealth);
elements.visit.addEventListener("click", recordVisit);
refreshHealth();
