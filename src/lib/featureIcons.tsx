import { BookPlus, FileText, Highlighter, Languages, MessageSquare, PenLine, Sparkles, Wand2 } from "lucide-react";
import type { AiFeatureIcon } from "../types";

export const FEATURE_ICON_OPTIONS: Array<{ value: AiFeatureIcon; label: string }> = [
  { value: "languages", label: "Languages" },
  { value: "wand", label: "Wand" },
  { value: "pen", label: "Pen" },
  { value: "sparkles", label: "Sparkles" },
  { value: "book-plus", label: "Book plus" },
  { value: "highlighter", label: "Highlighter" },
  { value: "file-text", label: "File text" },
  { value: "message", label: "Message" },
];

export function FeatureIcon({ icon, size = 16 }: { icon: AiFeatureIcon; size?: number }) {
  if (icon === "languages") return <Languages size={size} />;
  if (icon === "pen") return <PenLine size={size} />;
  if (icon === "sparkles") return <Sparkles size={size} />;
  if (icon === "book-plus") return <BookPlus size={size} />;
  if (icon === "highlighter") return <Highlighter size={size} />;
  if (icon === "file-text") return <FileText size={size} />;
  if (icon === "message") return <MessageSquare size={size} />;
  return <Wand2 size={size} />;
}

export function isFeatureIcon(value: string): value is AiFeatureIcon {
  return FEATURE_ICON_OPTIONS.some((option) => option.value === value);
}
