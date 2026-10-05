import test from "node:test";
import assert from "node:assert/strict";
import { MAX_PICK_BONUS, pickBonus, rankFilms, scoreFilm } from "../js/scoring.js";

test("pick bonus is linear from zero to the maximum", () => {
  assert.deepEqual(Array.from({ length: 5 }, (_, index) => pickBonus(index + 1, 5)),
    [0, 0.125, 0.25, 0.375, 0.5]);
  assert.equal(MAX_PICK_BONUS, 0.5);
});

test("a single participant receives no pick bonus", () => {
  assert.equal(pickBonus(1, 1), 0);
});

test("the pick bonus is applied once to the film average", () => {
  const result = scoreFilm([4, 4, 4, 4.5, 4.5], 5, 5);
  assert.equal(result.averageRating, 4.2);
  assert.equal(result.pickBonus, 0.5);
  assert.equal(result.finalScore, 4.7);
  assert.equal(scoreFilm([4, 4, 4, 4.5, 4.5], 5, 5).finalScore, 4.7);
});

test("final score is capped at five", () => {
  assert.equal(scoreFilm([5], 5, 5).finalScore, 5);
});

test("missing and invalid ratings are excluded from the average", () => {
  const result = scoreFilm([4, null, undefined, 0, 5.2, "", 4.5], 1, 5);
  assert.equal(result.ratingCount, 2);
  assert.equal(result.averageRating, 4.25);
  assert.equal(result.finalScore, 4.25);
  assert.equal(scoreFilm([], 1, 5).averageRating, null);
  assert.equal(scoreFilm([], 1, 5).finalScore, null);
  assert.equal(rankFilms([{ finalScore: null, averageRating: null }])[0].rank, null);
});

test("ranking uses full precision and shares ranks only for exact ties", () => {
  const ranked = rankFilms([
    { title: "C", finalScore: 4.7, averageRating: 4.2 },
    { title: "B", finalScore: 4.7, averageRating: 4.3 },
    { title: "A", finalScore: 4.7, averageRating: 4.3 },
    { title: "D", finalScore: 4.699999, averageRating: 4.4 },
  ]);
  assert.deepEqual(ranked.map(({ title, rank }) => [title, rank]), [
    ["B", 1], ["A", 1], ["C", 3], ["D", 4],
  ]);
});
