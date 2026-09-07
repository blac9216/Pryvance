import { useEffect, useState } from "react";

type Health = {
  status: string;
  version: string;
};

export function App() {
  const [health, setHealth] = useState<Health>();
  const [unavailable, setUnavailable] = useState(false);

  useEffect(() => {
    fetch("/api/v1/health", { headers: { Accept: "application/json" } })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.json() as Promise<Health>;
      })
      .then(setHealth)
      .catch(() => setUnavailable(true));
  }, []);

  const state = unavailable
    ? "The application API is unavailable."
    : health
      ? `Connected to Pryvance ${health.version}`
      : "Connecting to the application API…";

  return (
    <main>
      <section className="shell" aria-labelledby="page-title">
        <p className="eyebrow">Household finance, held close</p>
        <h1 id="page-title">Pryvance</h1>
        <p className="intro">
          Your private workspace for understanding the financial life of your Household.
        </p>
        <p className={`status ${health ? "connected" : ""}`} role="status">
          <span aria-hidden="true" />
          {state}
        </p>
      </section>
    </main>
  );
}
