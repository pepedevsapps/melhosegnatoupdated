export const MAX_PICK_BONUS = 0.5;

export function pickBonus(pickPosition, participantCount) {
  if (!Number.isInteger(pickPosition) || !Number.isInteger(participantCount)
      || participantCount < 1 || pickPosition < 1 || pickPosition > participantCount) {
    throw new RangeError("Pick position must be within the participant order.");
  }
  if (participantCount === 1) return 0;
  return MAX_PICK_BONUS * (pickPosition - 1) / (participantCount - 1);
}

export function scoreFilm(ratings, pickPosition, participantCount) {
  const validRatings = ratings.filter((rating) => Number.isFinite(Number(rating))
    && Number(rating) >= 1 && Number(rating) <= 5 && Number(rating) * 2 === Math.trunc(Number(rating) * 2));
  const averageRating = validRatings.length
    ? validRatings.reduce((sum, rating) => sum + Number(rating), 0) / validRatings.length
    : null;
  const bonus = pickBonus(pickPosition, participantCount);
  return {
    ratingCount: validRatings.length,
    averageRating,
    pickBonus: bonus,
    finalScore: averageRating === null ? null : Math.min(5, averageRating + bonus),
  };
}

export function rankFilms(films) {
  const sorted = films.map((film) => ({ ...film })).sort((a, b) => {
    const scoreA = a.finalScore;
    const scoreB = b.finalScore;
    if (scoreA === null && scoreB !== null) return 1;
    if (scoreA !== null && scoreB === null) return -1;
    if (scoreA !== scoreB) return (scoreB ?? 0) - (scoreA ?? 0);
    const averageA = a.averageRating;
    const averageB = b.averageRating;
    if (averageA === null && averageB !== null) return 1;
    if (averageA !== null && averageB === null) return -1;
    return (averageB ?? 0) - (averageA ?? 0);
  });
  let previous = null;
  let rank = 0;
  return sorted.map((film, index) => {
    if (film.finalScore === null) return { ...film, rank: null };
    const tied = previous && film.finalScore === previous.finalScore
      && film.averageRating === previous.averageRating;
    if (!tied) rank = index + 1;
    previous = film;
    return { ...film, rank };
  });
}
