import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

if (new URLSearchParams(window.location.search).has("window")) {
  document.documentElement.classList.add("translation-window-root");
  document.body.classList.add("translation-window-body");
}

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
