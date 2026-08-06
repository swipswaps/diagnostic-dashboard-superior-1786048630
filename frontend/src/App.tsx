import React, { useState, useEffect, useRef } from 'react';
import './App.css';

interface Diagnostic {
  id: number;
  run_id: string;
  component: string;
  status: string;
  line_number: number;
  line_text: string;
  logged_at: string;
}

const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:5001';
const WS_BASE = import.meta.env.VITE_WS_URL || 'ws://localhost:5001';

function App() {
  const [diagnostics, setDiagnostics] = useState<Diagnostic[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [logs, setLogs] = useState<string[]>([]);
  const [backendStatus, setBackendStatus] = useState<'checking' | 'online' | 'offline'>('checking');
  const [fallbackMode, setFallbackMode] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const logContainerRef = useRef<HTMLDivElement>(null);

  const checkBackend = async () => {
    try {
      const resp = await fetch(`${API_BASE}/health`);
      if (resp.ok) {
        setBackendStatus('online');
        setFallbackMode(false);
        return true;
      }
      throw new Error('Health check failed');
    } catch {
      setBackendStatus('offline');
      setFallbackMode(true);
      setLogs(prev => [...prev, '⚠️ Backend offline – using fallback mode (cached data)']);
      return false;
    }
  };

  const fetchDiagnostics = async () => {
    setLoading(true);
    try {
      const resp = await fetch(`${API_BASE}/api/diagnostics`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      setDiagnostics(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load data');
      const cached = localStorage.getItem('diagnostics_cache');
      if (cached) {
        try {
          const parsed = JSON.parse(cached);
          setDiagnostics(parsed);
          setLogs(prev => [...prev, '📦 Loaded cached data (backend unavailable)']);
        } catch { /* ignore */ }
      }
    } finally {
      setLoading(false);
    }
  };

  const connectWebSocket = () => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;
    const ws = new WebSocket(`${WS_BASE}/logs`);
    ws.onopen = () => setLogs(prev => [...prev, '🔌 Connected to log stream']);
    ws.onmessage = (event) => {
      setLogs(prev => [...prev, event.data]);
      if (logContainerRef.current) {
        logContainerRef.current.scrollTop = logContainerRef.current.scrollHeight;
      }
    };
    ws.onclose = () => {
      setLogs(prev => [...prev, '🔌 Log stream disconnected – reconnecting...']);
      setTimeout(connectWebSocket, 3000);
    };
    ws.onerror = () => setLogs(prev => [...prev, '❌ Log stream error']);
    wsRef.current = ws;
  };

  useEffect(() => {
    checkBackend().then(() => {
      fetchDiagnostics();
      fetch(`${API_BASE}/api/diagnostics`)
        .then(r => r.json())
        .then(data => localStorage.setItem('diagnostics_cache', JSON.stringify(data)))
        .catch(() => {});
    });
    connectWebSocket();
    const interval = setInterval(checkBackend, 30000);
    return () => {
      clearInterval(interval);
      wsRef.current?.close();
    };
  }, []);

  useEffect(() => {
    if (backendStatus === 'online') {
      const timer = setInterval(fetchDiagnostics, 10000);
      return () => clearInterval(timer);
    }
  }, [backendStatus]);

  return (
    <div className="app">
      <header className="header">
        <h1>🔬 Diagnostic Dashboard</h1>
        <div className="status-badge">
          <span className={`status-dot ${backendStatus}`} />
          {backendStatus === 'online' ? 'Backend Online' :
           backendStatus === 'offline' ? 'Fallback Mode' : 'Checking...'}
          {fallbackMode && ' (cached data)'}
        </div>
      </header>
      <main className="main">
        <section className="card diagnostics-card">
          <h2>📊 Diagnostics</h2>
          {loading && <div className="loading">Loading...</div>}
          {error && <div className="error">❌ {error}</div>}
          {!loading && !error && (
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr><th>ID</th><th>Run</th><th>Component</th><th>Status</th><th>Line</th><th>Logged</th></tr>
                </thead>
                <tbody>
                  {diagnostics.length === 0 ? (
                    <tr><td colSpan={6}>No diagnostic data available</td></tr>
                  ) : (
                    diagnostics.map(row => (
                      <tr key={row.id}>
                        <td>{row.id}</td>
                        <td>{row.run_id}</td>
                        <td>{row.component}</td>
                        <td><span className={`status-${row.status}`}>{row.status}</span></td>
                        <td>{row.line_number}</td>
                        <td>{new Date(row.logged_at).toLocaleString()}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          )}
        </section>
        <section className="card logs-card">
          <h2>📜 Real‑time Logs</h2>
          <div className="log-container" ref={logContainerRef}>
            {logs.length === 0 ? (
              <div className="log-placeholder">Waiting for logs...</div>
            ) : (
              logs.map((line, i) => (
                <div key={i} className="log-line">{line}</div>
              ))
            )}
          </div>
        </section>
      </main>
      <footer className="footer">
        <span>Built with ❤️ – {fallbackMode ? 'Fallback mode active' : 'Connected to backend'}</span>
        <button onClick={() => { fetchDiagnostics(); }} className="refresh-btn">⟳ Refresh</button>
      </footer>
    </div>
  );
}

export default App;
