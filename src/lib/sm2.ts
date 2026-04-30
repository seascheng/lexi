import type { ReviewRating, ReviewUpdate, WordEntry, WordStatus } from "../types";
import { addDays } from "./platform";

const ratingQuality: Record<ReviewRating, number> = {
  again: 2,
  hard: 3,
  good: 4,
  easy: 5,
};

export function scheduleReview(word: WordEntry, rating: ReviewRating): ReviewUpdate {
  const quality = ratingQuality[rating];
  const easeFactor = nextEaseFactor(word.ease_factor, quality);
  const interval = nextInterval(word, rating, quality);
  const reviewCount = word.review_count + 1;

  return {
    status: nextStatus(reviewCount, interval, rating),
    review_count: reviewCount,
    next_review: addDays(interval),
    ease_factor: easeFactor,
    interval,
  };
}

function nextEaseFactor(currentEase: number, quality: number) {
  const nextEase =
    currentEase + (0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02));
  return Math.max(1.3, Number(nextEase.toFixed(2)));
}

function nextInterval(word: WordEntry, rating: ReviewRating, quality: number) {
  if (quality < 3 || rating === "again") return 1;
  if (rating === "hard") return Math.max(1, Math.ceil(word.interval * 1.2));
  if (word.review_count === 0) return rating === "easy" ? 4 : 1;
  if (word.review_count === 1) return rating === "easy" ? 8 : 6;
  return Math.ceil(word.interval * nextEaseFactor(word.ease_factor, quality));
}

function nextStatus(reviewCount: number, interval: number, rating: ReviewRating): WordStatus {
  if (rating === "again") return "learning";
  if (reviewCount >= 4 && interval >= 21) return "mastered";
  return "learning";
}
