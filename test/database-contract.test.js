import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const [schema, app] = await Promise.all([
  readFile(new URL("../supabase/schema.sql", import.meta.url), "utf8"),
  readFile(new URL("../js/app.js", import.meta.url), "utf8"),
]);

function latestFunction(name) {
  const marker = new RegExp(`create(?: or replace)? function public\\.${name}\\b`, "g");
  const matches = [...schema.matchAll(marker)];
  const start = matches.at(-1)?.index ?? -1;
  assert.notEqual(start, -1, `${name} should be defined in schema.sql`);
  const end = schema.indexOf("$$;", start);
  assert.notEqual(end, -1, `${name} body should be closed`);
  return schema.slice(start, end + 3);
}

test("draft order is randomized once at start and then read from persisted rows", () => {
  const start = latestFunction("start_movie_night");
  const read = latestFunction("get_category_draft_state");
  const refreshStart = app.indexOf("async function refreshDashboard");
  const refreshEnd = app.indexOf("function renderEmpty", refreshStart);
  const refresh = app.slice(refreshStart, refreshEnd);
  assert.match(start, /row_number\(\) over\(order by random\(\),p\.id\)/);
  assert.match(start, /insert into public\.night_members\(night_id,user_id,pick_position\)/);
  assert.match(read, /order by nm\.pick_position/);
  assert.match(app, /rpc\("get_category_draft_state"/);
  assert.doesNotMatch(refresh, /Math\.random|order by random/);
  assert.match(refresh, /rpc\("get_category_draft_state"/);
  assert.match(app, /rpc\("start_movie_night"/);
});

test("category selection validates turn ownership and prevents duplicate claims", () => {
  const select = latestFunction("select_draft_category");
  assert.match(select, /v_current_user<>auth\.uid\(\)/);
  assert.match(select, /category_id=p_category_id/);
  assert.match(select, /Questa categoria è già stata scelta/);
  assert.match(select, /update public\.movie_nights set phase='nominations'/);
});

test("rating RPC permits own edits while the primary key prevents multiple active rows", () => {
  const rating = latestFunction("cast_movie_rating");
  assert.match(schema, /primary key\(drawn_film_id,user_id\)/);
  assert.match(rating, /values\(p_drawn_film_id,auth\.uid\(\),p_rating\)/);
  assert.match(rating, /on conflict\(drawn_film_id,user_id\) do update/);
  assert.doesNotMatch(rating, /update public\.movie_ratings set .*user_id/);
  assert.doesNotMatch(rating, /set phase='leaderboard'/);
  assert.match(schema, /revoke insert,update,delete on public\.profiles,public\.film_categories,public\.movie_nights,[\s\S]*?public\.drawn_films,public\.seen_votes,public\.movie_ratings from anon,authenticated/);
});

test("only the admin finalization RPC unlocks final scores; provisional rows remain labeled", () => {
  const finalize = latestFunction("finalize_movie_night");
  const finalScores = latestFunction("get_revealed_movies");
  const provisional = latestFunction("get_provisional_leaderboard");
  assert.match(finalize, /not public\.is_current_user_admin\(\)/);
  assert.match(finalize, /phase='complete'/);
  assert.match(finalScores, /phase='complete'/);
  assert.match(provisional, /phase<>'complete'/);
  assert.match(app, /Classifica provvisoria/);
  assert.match(app, /finalize_movie_night/);
});

test("SQL score calculation excludes absent ratings and adds the pick bonus once to the average", () => {
  const scores = latestFunction("calculate_night_film_scores");
  assert.match(scores, /avg\(r\.rating\)/);
  assert.match(scores, /count\(r\.user_id\)/);
  assert.match(scores, /least\(5::numeric,f\.average_rating\+f\.pick_bonus\)/);
  assert.match(scores, /rank\(\) over\(order by s\.raw_final_score desc nulls last,s\.average_rating desc nulls last\)/);
  assert.match(scores, /round\(r\.raw_final_score,2\)/);
});
