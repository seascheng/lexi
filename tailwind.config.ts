import type { Config } from "tailwindcss";

export default {
  darkMode: ["class"],
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        background: "rgb(var(--color-background) / var(--app-surface-opacity))",
        panel: "rgb(var(--color-panel) / var(--app-surface-opacity))",
        surface: "rgb(var(--color-surface) / var(--app-surface-opacity))",
        surfaceHover: "rgb(var(--color-surface-hover) / var(--app-surface-opacity))",
        border: "rgb(var(--color-border) / <alpha-value>)",
        muted: "rgb(var(--color-muted) / <alpha-value>)",
        strong: "rgb(var(--color-strong) / <alpha-value>)",
        content: "rgb(var(--color-content) / <alpha-value>)",
        input: "rgb(var(--color-input) / var(--app-surface-opacity))",
        example: "rgb(var(--color-example) / var(--app-surface-opacity))",
        floating: "rgb(var(--color-floating) / var(--app-surface-opacity))",
        accent: "rgb(var(--color-accent) / <alpha-value>)",
        accentHover: "rgb(var(--color-accent-hover) / <alpha-value>)",
        accentForeground: "rgb(var(--color-accent-foreground) / <alpha-value>)",
        danger: "rgb(var(--color-danger) / <alpha-value>)",
      },
    },
  },
  plugins: [],
} satisfies Config;
