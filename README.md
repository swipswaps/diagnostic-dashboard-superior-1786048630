# 🔬 Diagnostic Dashboard

A production‑ready diagnostic dashboard with real‑time log streaming, self‑healing fallback, and full CI/CD – built to exceed the capabilities of receipts-ocr.

## 🚀 Quick Start

```bash
# Clone and start everything
git clone https://github.com/swipswaps/diagnostic-dashboard-superior-1786048630.git
cd diagnostic-dashboard-superior-1786048630
./scripts/start.sh
```

Then open `http://localhost:5173`

## 📊 Architecture

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | React + TypeScript + Vite | Served via GitHub Pages |
| Backend | Flask + SQLite | REST API + SSE log streaming |
| Orchestration | Docker Compose | Local backend container |
| CI/CD | GitHub Actions (2 workflows) | Deploy + quality gates |
| Fallback | localStorage cache | Self‑healing when backend offline |

## 🔧 Features

- **Real‑time log streaming** – Server‑Sent Events from backend to frontend
- **Self‑healing fallback** – Cached data when backend unavailable
- **Quality gates** – ESLint, TypeScript, Ruff, mypy, bundle size checks
- **Lifecycle scripts** – `start.sh` / `stop.sh` with PID tracking
- **Docker Compose** – One‑command backend setup
- **GitHub Pages deployment** – Zero‑cost frontend hosting

## 📁 Project Structure

```
.
├── frontend/          # React + TypeScript + Vite
├── backend/           # Flask + SQLite
├── scripts/           # start.sh / stop.sh
├── .github/workflows/ # deploy.yml + quality.yml
└── data/              # SQLite database (auto‑created)
```

## 🔗 Links

- **Live site**: https://swipswaps.github.io/diagnostic-dashboard-superior-1786048630/
- **Repository**: https://github.com/swipswaps/diagnostic-dashboard-superior-1786048630

## 📜 License

MIT
