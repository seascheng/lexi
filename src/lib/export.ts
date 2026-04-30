import type { WordEntry } from "../types";

export function exportWords(words: WordEntry[], format: "json" | "csv") {
  const content = format === "json" ? toJson(words) : toCsv(words);
  const type = format === "json" ? "application/json" : "text/csv";
  downloadFile(content, `englist-words.${format}`, type);
}

function toJson(words: WordEntry[]) {
  return JSON.stringify(words, null, 2);
}

function toCsv(words: WordEntry[]) {
  const headers = [
    "word",
    "translation",
    "pos",
    "definition",
    "example",
    "status",
    "created_at",
    "review_count",
    "next_review",
    "ease_factor",
    "interval",
  ];
  const rows = words.map((word) => headers.map((header) => csvCell(word[header as keyof WordEntry])));
  return [headers.join(","), ...rows.map((row) => row.join(","))].join("\n");
}

function csvCell(value: unknown) {
  const text = value == null ? "" : String(value);
  return `"${text.split('"').join('""')}"`;
}

function downloadFile(content: string, filename: string, type: string) {
  const blob = new Blob([content], { type });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = filename;
  link.click();
  URL.revokeObjectURL(url);
}
