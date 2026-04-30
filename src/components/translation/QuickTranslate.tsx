import { Loader2, Wand2 } from "lucide-react";
import { FormEvent, useState } from "react";
import type { AppSettings, TranslationResult } from "../../types";
import { addWord } from "../../lib/database";
import { errorMessage } from "../../lib/errors";
import {
  showTranslationDisplay,
  showTranslationError,
  showTranslationLoading,
  translateText,
} from "../../lib/translation";
import { Button } from "../ui/Button";
import { Card } from "../ui/Card";
import { Field, Input } from "../ui/Field";
import { TranslationResultPanel } from "./TranslationResultPanel";

interface QuickTranslateProps {
  settings: AppSettings;
  onWordAdded: () => Promise<void>;
}

export function QuickTranslate({ settings, onWordAdded }: QuickTranslateProps) {
  const [text, setText] = useState("");
  const [result, setResult] = useState<TranslationResult | null>(null);
  const [error, setError] = useState("");
  const [isTranslating, setIsTranslating] = useState(false);

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    setError("");
    setIsTranslating(true);

    try {
      await showTranslationLoading(text, settings.displayMode);
      const nextResult = await translateText(text, settings);
      setResult(nextResult);
      await showTranslationDisplay(nextResult, settings.displayMode);

      if (settings.autoSave) {
        await addWord(nextResult);
        await onWordAdded();
      }
    } catch (translationError) {
      const message = errorMessage(translationError, "Translation failed.");
      setError(message);
      await showTranslationError(message, settings.displayMode);
    } finally {
      setIsTranslating(false);
    }
  }

  async function saveCurrentResult() {
    if (!result) return;
    await addWord(result);
    await onWordAdded();
  }

  return (
    <Card>
      <form className="grid gap-4" onSubmit={handleSubmit}>
        <Field label="Quick translate">
          <div className="flex flex-col gap-3 sm:flex-row">
            <Input
              className="flex-1"
              onChange={(event) => setText(event.target.value)}
              placeholder="Type a word or phrase, or use the global shortcut"
              value={text}
            />
            <Button disabled={isTranslating} type="submit" variant="primary" icon={isTranslating ? <Loader2 className="animate-spin" size={16} /> : <Wand2 size={16} />}>
              Translate
            </Button>
          </div>
        </Field>
        {error ? <p className="text-sm text-danger">{error}</p> : null}
      </form>

      {result ? (
        <div className="mt-5">
          <TranslationResultPanel result={result} onSave={settings.autoSave ? undefined : saveCurrentResult} />
        </div>
      ) : null}
    </Card>
  );
}
