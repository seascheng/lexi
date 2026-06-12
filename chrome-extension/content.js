// Lexi Chrome extension — content script.
// Listens for mouseup, checks for a non-empty selection, and POSTs the
// selected text to the Lexi desktop app's local HTTP server, which then
// shows the popup card with that text.
//
// Notes:
// - isCollapsed check skips mouseups that didn't drag a selection.
// - Trim to avoid sending whitespace-only selections.
// - swallow console errors so a closed Lexi doesn't spam the devtools console.

const ENDPOINT = "http://127.0.0.1:47291/selection";

document.addEventListener("mouseup", () => {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed) return;

  const text = selection.toString().trim();
  if (!text) return;

  fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text }),
  }).catch((err) => {
    console.log("[Lexi extension] could not reach Lexi:", err.message);
  });
});
